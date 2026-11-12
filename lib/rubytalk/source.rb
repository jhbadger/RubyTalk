# frozen_string_literal: true

require 'ripper'
require 'set'

module RubyTalk
  # Helpers that understand Ruby source text without running it.
  #
  # Ripper (Ruby's own parser, exposed as a library) is used to decide where a
  # statement ends, what a statement defines (a method, a class...) and to pull
  # the original text of a method out of the file it was defined in.
  module Source
    Description = Struct.new(:kind, :name)

    # One Ripper pass over a text that notes where each top-level statement ends, and what the parser
    # complained about, if anything. (Ripper's own sexp has no end positions: the closing `end` of a
    # def is not in it.) How it knows where a statement ends: Ripper reports every token as the lexer
    # scans it, and reports a finished statement (on_stmts_add) as soon as the token after it, which
    # is always a newline, `;` or the end of the text, has been scanned. So the last token scanned that
    # is not whitespace, a comment or a newline is the last token of the statement. Statements that
    # end on the same line (`a; b`) share one end.
    class Scan < Ripper
      Stmts = Struct.new(:ends)

      # Tokens that are not part of any statement: they never move a statement's end.
      LAYOUT = %i[sp nl ignored_nl ignored_sp comment embdoc_beg embdoc embdoc_end __end__ words_sep].freeze

      # The line each top-level statement ends on (1-based), one entry per statement.
      attr_reader :top_ends

      # What the parser said was wrong, as [[message, line], ...]; empty if the text is fine.
      attr_reader :problems

      def initialize(*)
        super
        @code_line = 0
        @top_ends = []
        @problems = []
      end

      SCANNER_EVENTS.each do |event|
        if LAYOUT.include?(event)
          define_method(:"on_#{event}") { |token| token }
        else
          define_method(:"on_#{event}") do |token|
            # A token's own final newline (a heredoc terminator, a line of heredoc text) is still on its line.
            last = lineno + token.to_s.chomp.count("\n")
            @code_line = last if last > @code_line
            token
          end
        end
      end

      # Parser events with a handler of their own below; every other one just answers nil.
      SPECIAL = %i[stmts_new void_stmt stmts_add program alias_error assign_error class_name_error param_error parse_error].freeze
      (PARSER_EVENTS - SPECIAL).each { |event| define_method(:"on_#{event}") { |*_args| nil } }

      def on_stmts_new
        Stmts.new([])
      end

      def on_void_stmt
        :void
      end

      def on_stmts_add(list, stmt)
        list.ends << @code_line unless stmt == :void
        list
      end

      def on_program(stmts)
        @top_ends = stmts.ends
        stmts
      end

      %i[alias_error assign_error class_name_error param_error].each do |event|
        define_method(:"on_#{event}") { |message, *_rest| @problems << [message, lineno] }
      end

      def on_parse_error(message)
        @problems << [message, lineno]
      end

      def compile_error(message)
        @problems << [message, lineno]
      end

      # Scans +text+. Returns the Scan, with #top_ends and #problems filled in.
      def self.of(text, file = '(source)')
        scan = new(text, file)
        scan.parse
        scan.problems << ['syntax error', 1] if scan.error? && scan.problems.empty?
        scan
      end
    end

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

    # Returns the SyntaxError for +text+, or nil if it is valid Ruby. CRuby's own compiler is asked when
    # there is one, because it also rejects things the parser alone accepts (a top-level `break`, a
    # repeated parameter name), and Accept wants to refuse those before anything is evaluated. Elsewhere
    # the parser (Ripper) does the check.
    def syntax_error(text, file = '(source)')
      return parse_error(text, file) unless defined?(RubyVM::InstructionSequence)

      RubyVM::InstructionSequence.compile(text, file)
      nil
    rescue SyntaxError => e
      e
    end

    # The SyntaxError Ripper finds in +text+, or nil. Parse errors only.
    def parse_error(text, file = '(source)')
      message, line = Scan.of(text, file).problems.first
      message && SyntaxError.new("#{file}:#{line}: #{message}")
    end

    def comment_only?(text)
      text.each_line.all? { |line| line.strip.empty? || line.strip.start_with?('#') }
    end

    # Splits text into top-level statements (each keeps the comments above it, and a line holding
    # several statements stays together). The text is parsed once, which makes this linear in its
    # length (it used to re-parse everything read so far after every line: 2,000 lines took 6 seconds).
    # Text that does not parse, or a split that does not check out, goes the slow way instead.
    def split_statements(text)
      groups = statement_groups(text)
      return split_statements_slowly(text) unless groups

      lines = text.lines
      statements = []
      counts = []
      from = 0
      groups.each do |last, count|
        statements << lines[from...last].join
        counts << count
        from = last
      end
      rest = lines[from..].join
      return split_statements_slowly(text) unless statements.zip(counts).all? { |piece, count| holds?(piece, count) }

      statements << rest unless rest.strip.empty? || comment_only?(rest)
      statements
    end

    # Does +piece+ parse to exactly +count+ statements? The check that the one-pass split did not
    # cut a statement in two, or run two together.
    def holds?(piece, count)
      sexp = Ripper.sexp(piece)
      !sexp.nil? && statements_of(sexp).size == count
    end

    # [[last_line, statement_count], ...] for the top-level statements of +text+ (statements that
    # end on the same line are one group), or nil if the text has a syntax error or the positions
    # are not usable, in which case the caller should not trust them.
    def statement_groups(text)
      scan = Scan.of(text)
      return nil unless scan.problems.empty?

      line_count = text.lines.size
      ends = scan.top_ends
      return nil unless ends.all? { |line| line.between?(1, line_count) } && ends == ends.sort

      ends.chunk { |line| line }.map { |line, same| [line, same.size] }
    end

    # The line each group of top-level statements ends on.
    def statement_ends(text)
      statement_groups(text)&.map(&:first)
    end

    # The original algorithm: a statement ends at the first line where everything so far parses.
    def split_statements_slowly(text)
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

    # [comment, rest]: the block of # comment lines at the top of +text+ (blank lines before
    # it are skipped) and everything after it. The comment is "" when there is none.
    def split_comment(text)
      lines = text.lines
      first = 0
      first += 1 while first < lines.size && lines[first].strip.empty?
      last = first
      last += 1 while last < lines.size && lines[last].strip.start_with?('#')
      [lines[first...last].join, lines[last..].join]
    end

    PROTOCOL_COMMENT = /\A\s*#\s*protocol:\s*(\S.*?)\s*\z/i.freeze

    # The protocol a method is filed under: the name in a `# protocol: accessing` comment among the
    # comment lines at the top of +text+ (the comment block above a `def`). nil if there is none.
    def protocol_of(text)
      text.each_line do |line|
        next if line.strip.empty?
        break unless line.strip.start_with?('#')

        match = PROTOCOL_COMMENT.match(line.chomp)
        return match[1].squeeze(' ') if match
      end
      nil
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
      name = mention_name(selector)
      !name.nil? && mention_set(text).include?(name)
    end

    # The token to look for when searching for uses of +selector+: a setter `name=` is looked for as
    # `name` (that is how it appears in `self.name = 1`). nil for what cannot be searched: bracket
    # selectors and the empty name.
    def mention_name(selector)
      name = selector.to_s
      name = name.chomp('=') unless name.match?(/\A[=!<>]=?\z|\A\[\]=?\z/) || name == '==='
      name.empty? || name.start_with?('[') ? nil : name
    end

    # Every name +text+ uses, as a Set: what #mentions? looks things up in. Computing it once and
    # keeping it (see Search) is what makes a second "Senders of" cheap.
    def mention_set(text)
      tokens = Ripper.lex(text).reject { |(_pos, type, _tok, _state)| %i[on_sp on_ignored_nl on_comment].include?(type) }
      names = Set.new
      tokens.each_with_index do |(_pos, type, token, _state), index|
        next unless %i[on_ident on_const on_op on_kw].include?(type)

        names << token unless definition_name?(tokens, index)
      end
      names
    end

    # Does +text+ use the instance or class variable +name+ (such as "@balance")? Token-based, so a
    # mention in a comment or a string does not count.
    def mentions_variable?(text, name)
      Ripper.lex(text).any? { |(_pos, type, token, _state)| %i[on_ivar on_cvar].include?(type) && token == name }
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
