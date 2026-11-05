# frozen_string_literal: true

module RubyTalk
  # The text-searching behind Find and Replace (Cmd-F), with no GUI so it can be tested
  # headlessly. Positions are CHARACTER offsets (what Ruby strings index by, and what Tk
  # counts), converted to Tk's "line.column" indices with Finder.index.
  module Finder
    class Error < StandardError; end

    # first..last (last exclusive) in the text; data is the MatchData (for \1 in replacements).
    Match = Struct.new(:first, :last, :data)

    module_function

    # Every non-empty match of +pattern+ in +text+, in order. A plain pattern is matched
    # literally; with regexp: true it is a Ruby regular expression.
    def matches(text, pattern, case_sensitive: false, regexp: false)
      return [] if pattern.to_s.empty?

      found = []
      text.scan(compile(pattern, case_sensitive, regexp)) do
        data = Regexp.last_match
        found << Match.new(data.begin(0), data.end(0), data) unless data.end(0) == data.begin(0)
      end
      found
    end

    def compile(pattern, case_sensitive, regexp)
      source = regexp ? pattern : Regexp.escape(pattern)
      Regexp.new(source, case_sensitive ? 0 : Regexp::IGNORECASE)
    rescue RegexpError => e
      raise Error, e.message
    end

    # Tk "line.column" for a character offset in +text+.
    def index(text, offset)
      before = text[0, offset].to_s
      newline = before.rindex("\n")
      "#{before.count("\n") + 1}.#{before.size - (newline ? newline + 1 : 0)}"
    end

    # A fast version of index for many offsets in the same text: a callable that maps a
    # character offset to Tk's "line.column" (one pass over the text, then a binary search).
    def indexer(text)
      starts = [0]
      text.each_char.with_index { |char, offset| starts << offset + 1 if char == "\n" }
      lambda do |offset|
        line = (starts.bsearch_index { |start| start > offset } || starts.size) - 1
        "#{line + 1}.#{offset - starts[line]}"
      end
    end

    # Which match to go to from +offset+: [match, wrapped]. Forward: the first match that starts
    # at or after it; backward: the last that ends at or before it; wrapping round if none.
    def pick(matches, offset, forward: true)
      return [nil, false] if matches.empty?

      if forward
        found = matches.find { |match| match.first >= offset }
        found ? [found, false] : [matches.first, true]
      else
        found = matches.reverse.find { |match| match.last <= offset }
        found ? [found, false] : [matches.last, true]
      end
    end

    # The text a match is replaced with. In a regular expression \1..\9, \0 and \& stand for the
    # groups and the whole match, and \\ for a backslash.
    def replacement(match, template, regexp: false)
      return template unless regexp

      template.gsub(/\\(\d|&|\\)/) do
        case Regexp.last_match(1)
        when '\\' then '\\'
        when '&' then match.data[0]
        else match.data[Regexp.last_match(1).to_i].to_s
        end
      end
    end

    # The whole text with every match replaced: [new_text, how_many].
    def replace_all(text, pattern, template, case_sensitive: false, regexp: false)
      found = matches(text, pattern, case_sensitive: case_sensitive, regexp: regexp)
      result = text.dup
      found.reverse_each do |match|
        result[match.first...match.last] = replacement(match, template, regexp: regexp)
      end
      [result, found.size]
    end
  end
end
