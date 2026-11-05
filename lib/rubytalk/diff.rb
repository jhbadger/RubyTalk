# frozen_string_literal: true

module RubyTalk
  # A small line diff (longest common subsequence), for comparing method versions.
  module Diff
    # Above this many line-pairs the table is too big to be worth building.
    MAX_CELLS = 250_000

    module_function

    # Lines of +after+ marked against +before+: [[' ', line], ['-', line], ['+', line], ...].
    # '-' lines are only in +before+, '+' lines only in +after+. Returns nil if too large.
    def lines(before, after)
      a = before.to_s.lines.map(&:chomp)
      b = after.to_s.lines.map(&:chomp)
      return nil if a.size * b.size > MAX_CELLS

      lcs = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
      (a.size - 1).downto(0) do |i|
        (b.size - 1).downto(0) do |j|
          lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : [lcs[i + 1][j], lcs[i][j + 1]].max
        end
      end
      walk(a, b, lcs)
    end

    def walk(a, b, lcs)
      result = []
      i = j = 0
      while i < a.size && j < b.size
        if a[i] == b[j]
          result << [' ', a[i]]
          i += 1
          j += 1
        elsif lcs[i + 1][j] >= lcs[i][j + 1]
          result << ['-', a[i]]
          i += 1
        else
          result << ['+', b[j]]
          j += 1
        end
      end
      a[i..].each { |line| result << ['-', line] }
      b[j..].each { |line| result << ['+', line] }
      result
    end

    # The same as text, one prefixed line each, ready to show in a pane.
    def unified(before, after)
      marked = lines(before, after) or return "(too large to compare)\n"
      marked.map { |mark, line| "#{mark} #{line}\n" }.join
    end

    def changed?(before, after)
      before.to_s.strip != after.to_s.strip
    end
  end
end
