# frozen_string_literal: true

require 'ripper'

module RubyTalk
  # Finds matching brackets for the code panes, with no GUI. Ruby's lexer is used, so brackets
  # inside strings, comments, symbols and regular expressions do not count. Offsets are
  # CHARACTER offsets (what Tk counts).
  module BracketMatcher
    OPEN = { on_lparen: '(', on_lbracket: '[', on_lbrace: '{', on_tlambeg: '{' }.freeze
    CLOSE = %i[on_rparen on_rbracket on_rbrace].freeze

    module_function

    # { offset => partner offset } for every balanced pair (both directions).
    def pairs(text)
      return {} if text.nil? || text.empty?

      starts = line_starts(text)
      lines = text.lines
      stack = []
      result = {}
      Ripper.lex(text).each do |(line, byte_column), type, token, _state|
        offset = starts.fetch(line - 1, 0) + lines.fetch(line - 1, '').byteslice(0, byte_column).to_s.size
        if OPEN.key?(type) || type == :on_embexpr_beg
          stack << (type == :on_embexpr_beg ? offset + token.size - 1 : offset) # the { of #{
        elsif CLOSE.include?(type) || type == :on_embexpr_end
          opener = stack.pop or next
          result[opener] = offset
          result[offset] = opener
        end
      end
      result
    rescue StandardError
      {}
    end

    # The bracket to mark for a cursor at +cursor+: the bracket just before it, else the one just
    # after it. Returns [bracket offset, partner offset], or nil.
    def match_near(text, cursor)
      [cursor - 1, cursor].each do |offset|
        next if offset.negative? || !'([{)]}'.include?(text[offset].to_s) || text[offset].to_s.empty?

        partner = pairs(text)[offset]
        return [offset, partner] if partner
      end
      nil
    end

    def line_starts(text)
      starts = [0]
      text.each_char.with_index { |char, offset| starts << offset + 1 if char == "\n" }
      starts
    end
  end
end
