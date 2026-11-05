# frozen_string_literal: true

require 'ripper'

module RubyTalk
  # Syntax highlighting: Ruby's own lexer (Ripper) turns source text into tagged
  # spans that the GUI applies as Tk text tags. No GUI code here, so it can be
  # tested headlessly.
  #
  # Ripper reports token positions as line + BYTE offset, but Tk counts
  # CHARACTERS, so columns are converted (this matters for any non-ASCII text).
  # The lexer tolerates unfinished code, so half-typed methods still highlight.
  module Highlighter
    # A tagged region; first/last are Tk text indices ("line.column", last exclusive).
    Span = Struct.new(:tag, :first, :last)

    TAGS = %i[keyword string comment number symbol constant variable regexp def_name].freeze

    # Foreground colours per tag, for a light and a dark text background.
    PALETTES = {
      light: { keyword: '#9b2393', string: '#1a7f37', comment: '#6e7781', number: '#0550ae', symbol: '#953800',
               constant: '#6f42c1', variable: '#c25a00', regexp: '#cf222e', def_name: '#0969da' },
      dark: { keyword: '#ff7ab2', string: '#7ee787', comment: '#8b949e', number: '#79c0ff', symbol: '#ffa657',
              constant: '#d2a8ff', variable: '#f0883e', regexp: '#ff7b72', def_name: '#58a6ff' }
    }.freeze

    # Larger texts are left uncoloured rather than slowing typing down.
    MAX_SOURCE = 60_000

    SIMPLE = {
      on_comment: :comment, on_embdoc_beg: :comment, on_embdoc: :comment, on_embdoc_end: :comment,
      on_const: :constant,
      on_ivar: :variable, on_gvar: :variable, on_cvar: :variable, on_backref: :variable,
      on_int: :number, on_float: :number, on_rational: :number, on_imaginary: :number,
      on_tstring_beg: :string, on_tstring_end: :string, on_heredoc_beg: :string, on_heredoc_end: :string,
      on_CHAR: :string, on_backtick: :string, on_qwords_beg: :string, on_words_beg: :string,
      on_qsymbols_beg: :string, on_symbols_beg: :string, on_embexpr_beg: :string, on_embexpr_end: :string,
      on_label: :symbol, on_label_end: :symbol, on_symbeg: :symbol
    }.freeze

    BLANK = %i[on_sp on_ignored_sp].freeze

    module_function

    # Spans for +source+, in order. Never raises on bad input.
    def spans(source)
      return [] if source.nil? || source.empty? || source.size > MAX_SOURCE

      text = source.dup.force_encoding(Encoding::UTF_8).scrub
      lines = text.lines
      tokens = Ripper.lex(text)
      state = { after_def: false, after_symbeg: false, regexp: 0 }
      result = []
      tokens.each_with_index do |((line, byte_column), type, token, _), index|
        tag = classify(type, token, tokens, index, state)
        result << span_for(tag, lines, line, byte_column, token) if tag
      end
      result
    rescue StandardError
      [] # highlighting is decoration: never let it break editing
    end

    # { tag => ["1.0", "1.3", "2.4", "2.9", ...] } flattened start/end pairs, ready
    # for one Tk `tag add` call per tag.
    def ranges_by_tag(source)
      spans(source).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |span, ranges|
        ranges[span.tag] << span.first << span.last
      end
    end

    def classify(type, token, tokens, index, state)
      after_symbeg = state[:after_symbeg]
      state[:after_symbeg] = false
      return nil if BLANK.include?(type)

      if state[:after_def] && name_token?(type) && !receiver?(tokens, index)
        state[:after_def] = false
        return :def_name
      end

      case type
      when :on_kw
        state[:after_def] = true if token == 'def'
        after_symbeg ? :symbol : :keyword
      when :on_tstring_content
        state[:regexp].positive? ? :regexp : :string
      when :on_regexp_beg
        state[:regexp] += 1
        :regexp
      when :on_regexp_end
        state[:regexp] -= 1 if state[:regexp].positive?
        :regexp
      when :on_symbeg
        state[:after_symbeg] = true
        :symbol
      else
        SIMPLE[type] || (after_symbeg && name_token?(type) ? :symbol : nil)
      end
    end

    def name_token?(type)
      %i[on_ident on_const on_op on_kw on_backtick on_ivar on_gvar on_cvar].include?(type)
    end

    # In `def self.name` the token before the period is the receiver, not the name.
    def receiver?(tokens, index)
      following = tokens[(index + 1)..]&.find { |(_, type, _, _)| !BLANK.include?(type) }
      !following.nil? && following[1] == :on_period
    end

    def span_for(tag, lines, line, byte_column, token)
      column = lines.fetch(line - 1, '').byteslice(0, byte_column).to_s.length
      text = token.chomp
      extra_lines = text.count("\n")
      if extra_lines.zero?
        last_line = line
        last_column = column + text.length
      else
        last_line = line + extra_lines
        last_column = text.split("\n", -1).last.to_s.length
      end
      Span.new(tag, "#{line}.#{column}", "#{last_line}.#{last_column}")
    end
  end
end
