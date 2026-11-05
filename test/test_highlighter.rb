# frozen_string_literal: true

# Tests for the syntax highlighter (no GUI).
#   ruby test/test_highlighter.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'rubytalk'

class HighlighterTest < Minitest::Test
  H = RubyTalk::Highlighter

  # The text each span covers, as [tag, text] pairs (so tests read like the source).
  def tagged(source)
    lines = source.lines
    H.spans(source).map do |span|
      line1, col1 = span.first.split('.').map(&:to_i)
      line2, col2 = span.last.split('.').map(&:to_i)
      text = if line1 == line2
               lines[line1 - 1][col1...col2]
             else
               lines[line1 - 1][col1..] + lines[line1...(line2 - 1)].join + lines[line2 - 1][0...col2]
             end
      [span.tag, text]
    end
  end

  def test_basic_tokens
    pairs = tagged("def foo(a)\n  puts 'hi' # note\n  @x = :sym + 42 + 1.5\nend")
    assert_includes pairs, [:keyword, 'def']
    assert_includes pairs, [:def_name, 'foo']
    assert_includes pairs, [:string, 'hi']
    assert_includes pairs, [:comment, '# note']
    assert_includes pairs, [:variable, '@x']
    assert_includes pairs, [:symbol, 'sym']
    assert_includes pairs, [:number, '42']
    assert_includes pairs, [:number, '1.5']
    assert_includes pairs, [:keyword, 'end']
    refute(pairs.any? { |_, text| text == 'puts' }, 'plain identifiers are not coloured')
  end

  def test_columns_are_characters_not_bytes
    # "é" is two bytes in UTF-8 but one character to Tk.
    spans = H.spans("é = :sym # ü\n")
    colon = spans.find { |s| s.tag == :symbol }
    assert_equal ['1.4', '1.5'], [colon.first, colon.last]
    comment = spans.find { |s| s.tag == :comment }
    assert_equal ['1.9', '1.12'], [comment.first, comment.last]
  end

  def test_method_names_and_receivers
    pairs = tagged("def self.name=(v); end\ndef +(o); end\ndef Foo.bar; end")
    assert_includes pairs, [:keyword, 'self'], 'self is the receiver, not the name'
    assert_includes pairs, [:def_name, 'name=']
    assert_includes pairs, [:def_name, '+']
    assert_includes pairs, [:constant, 'Foo']
    assert_includes pairs, [:def_name, 'bar']
  end

  def test_regexps_labels_words_and_constants
    pairs = tagged("x = /ab+/i\nh = {k: 1, 'q': 2}\nw = %w[a b]\nclass Foo < Bar; end")
    assert_includes pairs, [:regexp, 'ab+']
    assert_includes pairs, [:regexp, '/i']
    assert_includes pairs, [:symbol, 'k:']
    assert_includes pairs, [:symbol, "':"]
    assert_includes pairs, [:string, '%w[']
    assert_includes pairs, [:constant, 'Foo']
    assert_includes pairs, [:constant, 'Bar']
  end

  def test_multiline_tokens
    pairs = tagged("s = <<~EOS\n  line one\n  line two\nEOS\n=begin\nnote\n=end\n")
    assert_includes pairs, [:string, "line one"]
    assert_includes pairs, [:comment, '=begin']
    assert_includes pairs, [:comment, 'note']
    long = H.spans("x = \"a\nb\nc\"\n").find { |s| s.tag == :string && s.first != s.last && s.first.start_with?('1.5') }
    assert_equal ['1.5', '3.1'], [long.first, long.last], 'a string spanning lines ends on the right line and column'
  end

  def test_interpolation_keeps_code_coloured
    pairs = tagged('puts "a #{x + 1} b"')
    assert_includes pairs, [:number, '1']
    assert_includes pairs, [:string, 'a ']
    assert_includes pairs, [:string, ' b']
  end

  def test_symbols_after_colon
    pairs = tagged('a.send(:upcase); b = :+; c = :class; d = ?z')
    assert_includes pairs, [:symbol, 'upcase']
    assert_includes pairs, [:symbol, '+']
    assert_includes pairs, [:symbol, 'class'], 'a keyword after a colon is a symbol'
    assert_includes pairs, [:string, '?z']
  end

  def test_unfinished_and_broken_code_never_raises
    ['def foo(', "x = 'unterminated\nputs 2", '))) end end', "\u0000\u0001", 'class', '"#{'].each do |source|
      spans = H.spans(source)
      assert_kind_of Array, spans, source.inspect
    end
    assert_includes tagged('def foo('), [:def_name, 'foo']
  end

  def test_empty_nil_and_oversized_input
    assert_empty H.spans('')
    assert_empty H.spans(nil)
    assert_empty H.spans('x = 1 ' * H::MAX_SOURCE)
  end

  def test_invalid_utf8_is_tolerated
    spans = H.spans("x = 1 # \xFF\xFE\ny = 2".b)
    assert_kind_of Array, spans
    assert(spans.any? { |s| s.tag == :number })
  end

  def test_ranges_by_tag_groups_flat_pairs
    ranges = H.ranges_by_tag("def a; end\n")
    assert_equal %w[1.0 1.3 1.7 1.10], ranges[:keyword]
    assert_equal %w[1.4 1.5], ranges[:def_name]
  end

  def test_palettes_cover_every_tag
    H::PALETTES.each_value do |palette|
      assert_equal H::TAGS.sort, palette.keys.sort
      assert(palette.values.all? { |colour| colour.match?(/\A#\h{6}\z/) })
    end
    refute_equal H::PALETTES[:light], H::PALETTES[:dark]
  end

  def test_highlighting_is_fast_enough_to_run_on_every_keystroke
    source = ("def method_name(arg)\n  value = arg.map { |x| x * 2 } # comment\n  puts \"result: \#{value}\"\nend\n" * 100)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    H.ranges_by_tag(source)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.5, "400 lines took #{elapsed.round(3)}s"
  end
end
