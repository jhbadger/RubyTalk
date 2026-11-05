# frozen_string_literal: true

require 'ripper'

module RubyTalk
  # Helpers that understand Ruby source text without running it.
  #
  # Ripper (Ruby's own parser, exposed as a library) is used to decide where a
  # statement ends, what a statement defines (a method, a class...) and to pull
  # the original text of a method out of the file it was defined in.
  module Source
    Description = Struct.new(:kind, :name)

    module_function

    def statements_of(sexp)
      return [] unless sexp.is_a?(Array) && sexp[0] == :program

      sexp[1].reject { |node| node == [:void_stmt] }
    end

    # True when +text+ parses and contains at least one real statement.
    def complete_statement?(text)
      sexp = Ripper.sexp(text)
      !sexp.nil? && !statements_of(sexp).empty?
    end

    # Returns the SyntaxError for +text+, or nil if it compiles.
    def syntax_error(text, file = '(source)')
      RubyVM::InstructionSequence.compile(text, file)
      nil
    rescue SyntaxError => e
      e
    end

    def comment_only?(text)
      text.each_line.all? { |line| line.strip.empty? || line.strip.start_with?('#') }
    end

    # Splits text into top-level statements (each keeps the comments above it).
    # A statement ends at the first line where everything so far parses.
    def split_statements(text)
      statements = []
      buffer = +''
      text.each_line do |line|
        buffer << line
        next unless complete_statement?(buffer)

        statements << buffer
        buffer = +''
      end
      statements << buffer unless buffer.strip.empty? || comment_only?(buffer)
      statements
    end

    # What does this single statement define?
    #   :def    -> name is the method name
    #   :defs   -> `def self.name`
    #   :class / :module -> name is the (possibly qualified) constant name
    #   :other  -> anything else (attr_accessor, include, ...)
    def describe(statement)
      sexp = Ripper.sexp(statement)
      node = sexp && statements_of(sexp).first
      return Description.new(:other, nil) unless node.is_a?(Array)

      case node[0]
      when :def
        Description.new(:def, node[1][1])
      when :defs
        self_receiver?(node[1]) ? Description.new(:defs, node[3][1]) : Description.new(:other, nil)
      when :class
        named(:class, node[1])
      when :module
        named(:module, node[1])
      else
        Description.new(:other, nil)
      end
    end

    def named(kind, const_node)
      name = const_name(const_node)
      name ? Description.new(kind, name) : Description.new(:other, nil)
    end

    def self_receiver?(node)
      node.is_a?(Array) && node[0] == :var_ref && node[1].is_a?(Array) &&
        node[1][0] == :@kw && node[1][1] == 'self'
    end

    def const_name(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :const_ref, :var_ref, :top_const_ref then node[1].is_a?(Array) ? node[1][1] : nil
      when :const_path_ref
        parent = const_name(node[1])
        parent && "#{parent}::#{node[2][1]}"
      when :@const then node[1]
      end
    end

    # --- Pulling method source out of a file --------------------------------

    # Original text (with the comment block above it) of a Method/UnboundMethod
    # defined in Ruby, or nil for C methods and unreadable files.
    def method_source(method)
      file, line = method.source_location
      return nil unless file && line && File.file?(file)

      lines = File.readlines(file, encoding: 'UTF-8')
      extract_from_lines(lines, line - 1)
    rescue SystemCallError, EncodingError, ArgumentError
      nil
    end

    def extract_from_lines(lines, start_index, limit: 600)
      buffer = +''
      index = start_index
      while index < lines.size && index < start_index + limit
        buffer << lines[index]
        return dedent(leading_comments(lines, start_index) + buffer) if complete_statement?(buffer)

        index += 1
      end
      nil
    end

    def leading_comments(lines, start_index)
      comments = []
      index = start_index - 1
      while index >= 0 && lines[index].strip.start_with?('#')
        comments.unshift(lines[index])
        index -= 1
      end
      comments.join
    end

    # Removes common indentation, unless a heredoc is present (dedenting would
    # change the contents of a plain heredoc).
    def dedent(text)
      return text if text.match?(/<<[~-]?['"]?\w/)

      indents = text.each_line.reject { |l| l.strip.empty? }.map { |l| l[/\A[ \t]*/].size }
      margin = indents.min.to_i
      return text if margin.zero?

      text.each_line.map { |l| l.strip.empty? ? l : l[margin..] }.join
    end
    # --- Finding uses of a selector ------------------------------------------

    # Does +text+ call/mention the method name +selector+? Token-based (Ripper's
    # lexer), so comments and string contents do not count and `def selector`
    # (a definition, not a use) is skipped. Symbols (`send(:name)`, `&:name`)
    # count as uses. Approximate by nature: a local variable with the same name
    # also matches, and bracket selectors ([] and []=) are not searched.
    def mentions?(text, selector)
      name = selector.to_s
      name = name.chomp('=') unless name.match?(/\A[=!<>]=?\z|\A\[\]=?\z/) || name == '==='
      return false if name.empty? || name.start_with?('[')

      tokens = Ripper.lex(text).reject { |(_pos, type, _tok, _state)| %i[on_sp on_ignored_nl on_comment].include?(type) }
      tokens.each_with_index.any? do |(_pos, type, token, _state), index|
        next false unless token == name && %i[on_ident on_const on_op on_kw].include?(type)

        !definition_name?(tokens, index)
      end
    end

    # True when the token at +index+ is the name in `def name` / `def self.name`.
    def definition_name?(tokens, index)
      before = ->(offset) { index - offset >= 0 ? tokens[index - offset] : nil }
      return true if before.call(1)&.then { |t| t[1] == :on_kw && t[2] == 'def' }

      period = before.call(1)
      receiver = before.call(2)
      keyword = before.call(3)
      period && period[1] == :on_period && receiver && receiver[1] == :on_kw &&
        receiver[2] == 'self' && keyword && keyword[1] == :on_kw && keyword[2] == 'def'
    end
  end
end
