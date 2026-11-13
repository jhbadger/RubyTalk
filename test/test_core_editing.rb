# frozen_string_literal: true

# Auto-indent, bracket matching, find and replace (no GUI).
#   ruby test/test_core_editing.rb

require_relative 'support/core_case'

class CoreEditingTest < CoreCase
  def indenter
    RubyTalk::Indenter
  end

  def finder
    RubyTalk::Finder
  end

  def spans(found)
    found.map { |m| [m.first, m.last] }
  end

  # --- Auto-indent and bracket matching ---------------------------------------


  def test_next_indent_after_lines_that_open_a_block
    {
      'def foo' => '  ', '  if x' => '    ', 'foo do |x|' => '  ', 'items.each { |x|' => '  ', 'x = [' => '  ',
      'class << self' => '  ', 'x = if cond' => '  ', 'end.map do |y|' => '  ', 'rescue Foo => e' => '  ',
      'def foo # comment' => '  ', 'while x do' => '  ', 'begin' => '  ', 'case x' => '  ', 'loop do' => '  ',
      'x = ->(a) {' => '  ', 'def foo=(v)' => '  ', 'def ==(o)' => '  ', 'value = begin' => '  ', 'module Foo' => '  ',
      'foo(a,' => '  ', 'h = {' => '  ', 'private def foo' => '  ', "\tdef foo" => "\t  ", '  else' => '    ',
      '  when 1' => '    ', 'ensure' => '  ', 'elsif y' => '  '
    }.each { |line, expected| assert_equal expected, indenter.next_indent(line), line.inspect }
  end

  def test_next_indent_after_lines_that_do_not
    ['x = [1, 2]', 'def a; end', 'def a = 1', 'def a(x) = x * 2', 'puts 1 if x', '  return if x', 'end', '} ',
     'puts "("', '# def foo', '', '    end', '  x = 1'].each do |line|
      assert_equal indenter.leading_whitespace(line), indenter.next_indent(line), line.inspect
    end
  end

  def test_closers_typed_on_their_own_line_up_with_their_opener
    assert_equal '  end', indenter.dedented("def foo\n  if x\n    a\n", '    end')
    assert_equal '  else', indenter.dedented("def foo\n  if x\n    a\n", '    else')
    assert_equal '}', indenter.dedented("h = {\n  a: 1\n", '  }')
    assert_equal '  when 2', indenter.dedented("case x\n  when 1\n    a\n", '    when 2')
    assert_equal 'end', indenter.dedented("def foo\n  a\n", '  end')
    assert_equal '  end', indenter.dedented("class A\n  def foo\n    a\n\n", '    end'), 'blank lines above are skipped'
  end

  def test_dedent_leaves_other_text_and_hand_indented_code_alone
    assert_nil indenter.dedented("def foo\n  a\n", 'end'), 'not at the auto-indented position'
    assert_nil indenter.dedented("def foo\n  a\n", '  else_x = 1')
    assert_nil indenter.dedented("def foo\n  a\n", '  when: 1')
    assert_nil indenter.dedented("def foo\n  a\n", '  endless = 1')
    assert_nil indenter.dedented("def foo\n  a\n", '  b')
    assert_nil indenter.dedented('', 'end')
    assert_nil indenter.dedented("x\n", 'end'), 'nothing to line up with'
  end

  def test_bracket_pairs
    pairs = RubyTalk::BracketMatcher.pairs('foo(a, [1, {b: 2}])')
    assert_equal({ 3 => 18, 18 => 3, 7 => 17, 17 => 7, 11 => 16, 16 => 11 }, pairs)
    assert_empty RubyTalk::BracketMatcher.pairs("\"(\" # ) (\n:'[' "), 'strings, comments and symbols do not count'
    assert_empty RubyTalk::BracketMatcher.pairs('a = %w[x y] =~ /[a-z]/'), 'nor word lists or regexps'
    assert_equal({ 1 => 3, 3 => 1 }, RubyTalk::BracketMatcher.pairs('é(x)'), 'character offsets')
    assert_equal({ 2 => 4, 4 => 2 }, RubyTalk::BracketMatcher.pairs('"#{x}"'), 'the braces of interpolation')
    assert_equal({ 2 => 6, 6 => 2 }, RubyTalk::BracketMatcher.pairs('->{ 1 }'))
    assert_empty RubyTalk::BracketMatcher.pairs('foo(a')
    assert_empty RubyTalk::BracketMatcher.pairs('')
    assert_equal({ 0 => 1, 1 => 0, 3 => 4, 4 => 3 }, RubyTalk::BracketMatcher.pairs("()\n()".sub("\n", ' ')))
  end

  def test_bracket_match_near_the_cursor
    match = RubyTalk::BracketMatcher.method(:match_near)
    assert_equal [5, 3], match.call('foo(a)', 6), 'just after the closer'
    assert_equal [3, 5], match.call('foo(a)', 4), 'just after the opener'
    assert_equal [3, 5], match.call('foo(a)', 3), 'just before the opener'
    assert_nil match.call('foo(a', 4), 'no partner'
    assert_nil match.call('foo(a)', 0), 'not next to a bracket'
    assert_nil match.call('', 0)
  end

  # --- Find and replace ----------------------------------------------------



  def test_finder_plain_matches
    text = "alpha beta Alpha\nalpha"
    assert_equal [[0, 5], [11, 16], [17, 22]], spans(finder.matches(text, 'alpha')), 'case-insensitive by default'
    assert_equal [[0, 5], [17, 22]], spans(finder.matches(text, 'alpha', case_sensitive: true))
    assert_equal [[0, 3]], spans(finder.matches('a.b a-b', 'a.b')), 'a plain pattern is literal: the dot is not a wildcard'
    assert_empty finder.matches(text, '')
    assert_empty finder.matches(text, 'zzz')
    assert_empty finder.matches('', 'a')
  end

  def test_finder_regexp_matches_and_errors
    text = 'x1 y22 z333'
    assert_equal %w[1 22 333], finder.matches(text, '\d+', regexp: true).map { |m| m.data[0] }
    assert(finder.matches(text, 'x*', regexp: true).none? { |m| m.first == m.last }, 'empty matches are skipped')
    assert_equal [[0, 1]], spans(finder.matches("a\nb", '^a', regexp: true))
    assert_raises(RubyTalk::Finder::Error) { finder.matches('x', '(', regexp: true) }
    assert_equal 1, finder.matches('a(b', '(').size, 'the same text is fine as a plain pattern'
  end

  def test_finder_offsets_are_characters_and_convert_to_tk_indices
    text = "é = :sym\nsecond é line"
    match = finder.matches(text, 'sym').first
    assert_equal [5, 8], [match.first, match.last], 'characters, not bytes'
    assert_equal '1.5', finder.index(text, match.first)
    assert_equal '2.0', finder.index(text, finder.matches(text, 'second').first.first)
    assert_equal '2.7', finder.index(text, finder.matches(text, 'é').last.first)
    assert_equal '1.0', finder.index(text, 0)
    assert_equal '2.0', finder.index("a\nb", 2)
    assert_equal '1.1', finder.index('a', 1)
  end

  def test_finder_indexer_agrees_with_index
    text = "é = :sym\nsecond é line\n\nlast"
    indexer = finder.indexer(text)
    (0..text.size).each { |offset| assert_equal finder.index(text, offset), indexer.call(offset), "offset #{offset}" }
    assert_equal '1.0', finder.indexer('').call(0)
  end

  def test_finder_pick_moves_forward_and_back_and_wraps
    found = finder.matches('a b a b a', 'a')
    assert_equal [0, 4, 8], found.map(&:first)
    pick = ->(offset, forward) { finder.pick(found, offset, forward: forward).then { |m, wrapped| [m.first, wrapped] } }
    assert_equal [0, false], pick.call(0, true)
    assert_equal [4, false], pick.call(1, true)
    assert_equal [8, false], pick.call(5, true)
    assert_equal [0, true], pick.call(9, true), 'forward past the last wraps to the first'
    assert_equal [4, false], pick.call(8, false)
    assert_equal [8, true], pick.call(0, false), 'backward before the first wraps to the last'
    assert_equal [nil, false], finder.pick([], 0)
  end

  def test_finder_replacements
    match = finder.matches('John Smith', '(\w+) (\w+)', regexp: true).first
    assert_equal 'Smith, John', finder.replacement(match, '\2, \1', regexp: true)
    assert_equal 'John Smith!', finder.replacement(match, '\0!', regexp: true)
    assert_equal '[John Smith]', finder.replacement(match, '[\&]', regexp: true)
    assert_equal 'a\b', finder.replacement(match, 'a\\\\b', regexp: true), 'two backslashes make one'
    assert_equal '\1 stays', finder.replacement(finder.matches('x', 'x').first, '\1 stays'), 'plain replacements are literal'

    assert_equal ['Smith, John', 1], finder.replace_all('John Smith', '(\w+) (\w+)', '\2, \1', regexp: true)
    assert_equal ['b b b', 3], finder.replace_all('a a A', 'a', 'b')
    assert_equal ['b b A', 2], finder.replace_all('a a A', 'a', 'b', case_sensitive: true)
    assert_equal ['a a A', 0], finder.replace_all('a a A', 'q', 'z')
    assert_equal ['é-é', 1], finder.replace_all('éxé', 'x', '-')
    assert_equal ['ñññ', 3], finder.replace_all('aaa', 'a', 'ñ'), 'replacing with multi-byte text'
  end
end
