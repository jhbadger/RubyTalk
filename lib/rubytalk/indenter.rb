# frozen_string_literal: true

require 'ripper'

module RubyTalk
  # Auto-indent for the code panes, with no GUI so it can be tested headlessly.
  #
  #   next_indent(line)            the indentation for the line after +line+ (Return)
  #   dedented(previous, line)     the line with `end` / `else` / `}` ... moved back to line up
  #                                with what it closes, or nil if it should not change
  #
  # Lines are read with Ruby's lexer, so keywords inside strings and comments do not count.
  # It is a heuristic, not a parser: it favours predictable behaviour over cleverness.
  module Indenter
    STEP = '  '

    # Keywords that open a block when they start a line.
    OPENERS = %w[def class module if unless while until case begin for].freeze
    # Their loop-ish partners: after `while x do` the `do` is not a second block.
    LOOPS = %w[while until for].freeze
    # Clauses that sit level with their opener but whose body is indented again.
    CLAUSES = %w[else elsif when in rescue ensure].freeze
    CLOSING_KEYWORDS = %w[end].freeze

    OPEN_TOKENS = %i[on_lparen on_lbracket on_lbrace on_tlambeg on_embexpr_beg].freeze
    CLOSE_TOKENS = %i[on_rparen on_rbracket on_rbrace on_embexpr_end].freeze
    SKIPPED = %i[on_sp on_ignored_sp on_comment on_nl on_ignored_nl].freeze

    # A line starting with one of these (typed on its own) lines up with what it closes.
    DEDENT_START = /\A(?:(?:end|else|elsif|when|in|rescue|ensure)(?![\w?!:=])|[\]})])/.freeze

    module_function

    def leading_whitespace(line)
      line[/\A[ \t]*/]
    end

    # The indentation for the line after +line+.
    def next_indent(line)
      base = leading_whitespace(line)
      return base + STEP if clause?(line) || opens_block?(line)

      base
    end

    # Does the line leave a block, bracket or brace open at its end?
    def opens_block?(line)
      tokens = significant(line)
      return false if tokens.empty?

      tokens = tokens.drop_while { |token| closing?(token) } # `end.map do |x|`: the leading `end` is not ours
      depth = 0
      tokens.each_with_index do |token, index|
        depth += token_effect(tokens, token, index)
      end
      depth.positive?
    end

    # A line that begins an else/when/rescue clause: its body is indented under it.
    def clause?(line)
      first = significant(line).first
      !first.nil? && first[1] == :on_kw && CLAUSES.include?(first[2])
    end

    def significant(line)
      Ripper.lex(line.to_s).reject { |(_pos, type, _token, _state)| SKIPPED.include?(type) }
    rescue StandardError
      []
    end

    def closing?(token)
      (token[1] == :on_kw && CLOSING_KEYWORDS.include?(token[2])) || CLOSE_TOKENS.include?(token[1])
    end

    # +1 for something that opens, -1 for something that closes, else 0.
    def token_effect(tokens, token, index)
      type = token[1]
      text = token[2]
      return 1 if OPEN_TOKENS.include?(type)
      return -1 if CLOSE_TOKENS.include?(type)
      return 0 unless type == :on_kw

      keyword_effect(tokens, text, index)
    end

    def keyword_effect(tokens, text, index)
      case text
      when 'end' then -1
      when 'def' then endless_def?(tokens, index) ? 0 : 1 # also `private def name`
      when 'do' then loop_do?(tokens) ? 0 : 1
      when 'begin', 'case' then 1
      when 'class', 'module' then index.zero? ? 1 : 0
      when *OPENERS then opens_here?(tokens, index) ? 1 : 0
      else 0
      end
    end

    # `if`, `unless`, `while`, `until` open a block at the start of a line, or after an operator
    # (`x = if cond`); after an expression they are modifiers (`puts 1 if x`).
    def opens_here?(tokens, index)
      return true if index.zero?

      before = tokens[index - 1]
      before[1] == :on_op || %i[on_lparen on_lbracket on_lbrace on_comma on_semicolon].include?(before[1]) ||
        (before[1] == :on_kw && %w[then do else].include?(before[2])) # `return if x` is a modifier
    end

    # `while cond do` : the `do` belongs to the loop, which already opened.
    def loop_do?(tokens)
      first = tokens.first
      first[1] == :on_kw && LOOPS.include?(first[2])
    end

    # `def name(args) = expression` has no `end`.
    def endless_def?(tokens, index = 0)
      depth = 0
      tokens.drop(index + 2).each do |token|
        depth += 1 if OPEN_TOKENS.include?(token[1])
        depth -= 1 if CLOSE_TOKENS.include?(token[1])
        return true if depth.zero? && token[1] == :on_op && token[2] == '='
      end
      false
    end

    # +line+ with its indentation moved back to line up with what it closes, when +line+ is a
    # closer typed at exactly the indentation auto-indent gave it. +previous+ is the text above
    # the line. Returns nil when nothing should change (so navigating over existing code, or
    # code indented some other way, is left alone).
    def dedented(previous, line)
      stripped = line.to_s.strip
      return nil unless stripped.match?(DEDENT_START)

      lines = previous.to_s.lines.map(&:chomp)
      above = lines.reverse.find { |text| !text.strip.empty? } or return nil
      current = leading_whitespace(line)
      return nil unless current == next_indent(above)

      opener = lines.reverse.find { |text| !text.strip.empty? && leading_whitespace(text).size < current.size }
      return nil unless opener

      "#{leading_whitespace(opener)}#{line.lstrip}"
    end
  end
end
