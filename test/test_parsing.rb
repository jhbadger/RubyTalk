# frozen_string_literal: true

# Parsing robustness and speed: one-pass statement splitting, Ripper-based syntax errors,
# Search caching, and the debugger's raise recording.
#   ruby test/test_parsing.rb

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'timeout'
require 'rubytalk'
require 'rubytalk/gui'

class ParsingTest < Minitest::Test
  include RubyTalk

  def setup
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk-parsing')
    RubyTalk.changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
  end

  def teardown
    Evaluator.max_records = Evaluator::MAX_RECORDS
    FileUtils.remove_entry(@dir)
  end

  # --- split_statements ------------------------------------------------------------------------

  # What the slow, original algorithm says. The fast one must agree wherever the old one was right.
  def both(text)
    [Source.split_statements(text), Source.split_statements_slowly(text)]
  end

  def assert_same_split(text, message = nil)
    fast, slow = both(text)
    assert_equal slow, fast, message
  end

  def test_the_usual_shapes_split_exactly_as_before
    [
      "class A\n  def a\n    1\n  end\nend\n",
      "# comment above\ndef a; 1; end\n\n# another\n# lines\ndef b\n  2\nend\n",
      "attr_accessor :x\ninclude Comparable\ndef a; end\n",
      "x = [1,\n     2]\ny = { a: 1,\n      b: 2 }\n",
      "def a\n  <<~TEXT\n    hello\n    # not a comment\n  TEXT\nend\n",
      "x = <<~ONE + <<~TWO\n  1\nONE\n  2\nTWO\ny = 3\n",
      "foo do |a|\n  a + 1\nend\nbar { |b| b }\n",
      "if a\n  1\nelse\n  2\nend\nb = 3\n",
      "=begin\ndocs\n=end\ndef a; end\n",
      "def a; end\n# trailing comment\n",
      "def a; end\n\n\n",
      "a = 1; b = 2\nc = 3\n",
      "def a = 1\ndef b(x) =\n  x + 1\n",
      "case x\nwhen 1 then :a\nelse :b\nend\n",
      "puts 'no trailing newline'",
      "# only a comment\n",
      "\n\n",
      ''
    ].each { |text| assert_same_split(text, text.inspect) }
  end

  def test_statements_keep_the_comments_above_them_and_trailing_comments_on_their_line
    parts = Source.split_statements("# about a\ndef a; end # why\n\n# about b\ndef b; end\n# tail\n")
    assert_equal ["# about a\ndef a; end # why\n", "\n# about b\ndef b; end\n"], parts
  end

  def test_two_statements_on_one_line_stay_together
    assert_equal ["a = 1; b = 2\n", "c = 3\n"], Source.split_statements("a = 1; b = 2\nc = 3\n")
  end

  def test_a_backslash_continued_statement_is_one_statement
    text = "warn \"one \" \\\n     \"two\"\nx = 1\n"
    assert_equal ["warn \"one \" \\\n     \"two\"\n", "x = 1\n"], Source.split_statements(text)
    refute_equal Source.split_statements_slowly(text), Source.split_statements(text),
                 'the old algorithm cut it after the first line, which was a bug'
  end

  def test_a_leading_dot_chain_is_one_statement
    assert_equal ["foo\n  .bar\n  .baz\n", "x = 1\n"], Source.split_statements("foo\n  .bar\n  .baz\nx = 1\n")
  end

  def test_text_that_does_not_parse_still_splits_the_old_way
    text = "def a; end\ndef b\n"
    assert_nil Source.statement_ends(text)
    assert_equal ["def a; end\n", "def b\n"], Source.split_statements(text)
    assert_equal Source.split_statements_slowly(text), Source.split_statements(text)
  end

  def test_a_big_class_splits_in_linear_time
    body = +"class RtBigOne\n"
    1500.times { |i| body << "  def m#{i}(a)\n    if a\n      [a].map { |v| v + #{i} }\n    end\n  end\n" }
    body << "end\n"
    statements = nil
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC).then do |start|
      statements = Source.split_statements(body)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end
    assert_equal [body], statements
    assert_operator elapsed, :<, 2.0, "7,500 lines took #{elapsed.round(2)}s (the old way needed about a minute)"
  end

  def test_statement_ends_reports_lines_and_merges_shared_lines
    assert_equal [1, 3], Source.statement_ends("a = 1; b = 2\n# c\nfoo\n")
    assert_equal [4], Source.statement_ends("class A\n  def a\n  end\nend\n")
    assert_equal [], Source.statement_ends("# nothing\n")
  end

  def test_real_library_files_split_the_same_both_ways
    # Small files only: the slow algorithm it is compared with is quadratic.
    files = Dir[File.join(RbConfig::CONFIG['rubylibdir'], '*.rb')].select { |file| File.size(file) < 5000 }.first(40)
    skip 'no library files found' if files.empty?
    files.each do |file|
      text = File.read(file, encoding: 'UTF-8')
      next unless Source.statement_ends(text)

      assert_equal Source.split_statements_slowly(text), Source.split_statements(text), file
    end
  end

  # --- Search caching ------------------------------------------------------------------------------

  def labels(selector)
    Search.senders(selector, RubyTalk.changes).map(&:label)
  end

  def test_mention_helpers
    assert_equal 'name', Source.mention_name('name=')
    assert_equal '==', Source.mention_name('==')
    assert_equal '<=', Source.mention_name('<=')
    assert_nil Source.mention_name('[]')
    assert_nil Source.mention_name('')
    names = Source.mention_set("def run(a)\n  helper(a) + @x.size\n  self.name = :sym\nend\n")
    assert_includes names, 'helper'
    assert_includes names, 'name'
    assert_includes names, 'sym'
    refute_includes names, 'run', 'the name in a def is not a use'
    assert Source.mentions?("foo.bar(1)\n", 'bar')
    refute Source.mentions?("# bar\n'bar'\n", 'bar')
  end

  def test_a_second_search_reads_nothing_again_and_gives_the_same_answer
    Search.clear_caches
    cold = labels('each_pair')
    refute_empty cold
    assert_operator Search.cache_sizes.first, :>, 0, 'the methods that mention it are remembered'
    warm = Source.stub(:extract_from_lines, ->(*) { raise 'a cached search must not extract source again' }) { labels('each_pair') }
    assert_equal cold, warm
  end

  def test_changes_are_found_and_a_new_version_replaces_the_old_one
    Compiler.accept("class RtSearch1\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def one\n  rt_cache_marker_a\nend\n", klass: RtSearch1, changes: RubyTalk.changes)
    assert_equal ['RtSearch1#one'], labels('rt_cache_marker_a')
    assert_equal ['RtSearch1#one'], labels('rt_cache_marker_a'), 'and again, from the cache'

    Compiler.accept("def one\n  rt_cache_marker_b\nend\n", klass: RtSearch1, changes: RubyTalk.changes)
    assert_empty labels('rt_cache_marker_a'), 'an Accept needs no invalidation: the old text is simply gone'
    assert_equal ['RtSearch1#one'], labels('rt_cache_marker_b')
  ensure
    Object.send(:remove_const, :RtSearch1) if Object.const_defined?(:RtSearch1)
  end

  def test_editing_a_source_file_makes_its_cached_entries_stale
    file = File.join(@dir, 'cached_file.rb')
    File.write(file, "class RtSearch2\n  def go\n    rt_file_marker_a\n  end\nend\n")
    load file
    assert_equal ['RtSearch2#go'], labels('rt_file_marker_a')
    assert_equal ['RtSearch2#go'], labels('rt_file_marker_a')

    File.write(file, "class RtSearch2\n  def go\n    rt_file_marker_b\n  end\nend\n")
    File.utime(Time.now + 10, Time.now + 10, file)
    assert_empty labels('rt_file_marker_a')
    assert_equal ['RtSearch2#go'], labels('rt_file_marker_b')
  ensure
    Object.send(:remove_const, :RtSearch2) if Object.const_defined?(:RtSearch2)
  end

  def test_implementors_and_searches_for_unsearchable_names_are_unaffected
    assert_empty Search.senders('[]', RubyTalk.changes)
    assert_empty Search.senders('', RubyTalk.changes)
    assert(Search.implementors('upcase').any? { |hit| hit.klass == String })
  end

  def test_the_cache_is_emptied_when_it_grows_too_large
    original = Search::MAX_CACHED
    Search.send(:remove_const, :MAX_CACHED)
    Search.const_set(:MAX_CACHED, 5)
    Search.clear_caches
    result = labels('each_pair')
    refute_empty result, 'a tiny cache changes speed, never the answer'
    assert_operator Search.cache_sizes.first, :<=, 5
  ensure
    Search.send(:remove_const, :MAX_CACHED)
    Search.const_set(:MAX_CACHED, original)
    Search.clear_caches
  end

  # --- the debugger's raise recording --------------------------------------------------------------

  FAILS = "def rt_inner(value)\n  value.fetch(:missing)\nend\nrt_inner({})\n"

  def test_recording_is_on_by_default_with_a_cap_of_100
    assert_equal 100, Evaluator.max_records
    result = Evaluator.evaluate(FAILS, Evaluator.new_binding)
    refute result.ok
    refute_nil result.failure.binding, 'the binding at the raise is kept for the debugger'
  end

  def test_the_cap_limits_how_many_raises_are_remembered
    Evaluator.max_records = 3
    seen = Evaluator.evaluate("10.times { |i| begin; raise \"e\#{i}\"; rescue; end }\nraise 'last'", Evaluator.new_binding)
    refute seen.ok
    assert_equal 'last', seen.error.message
    refute_nil seen.failure.binding, 'the raise that matters is always among the newest'
  end

  def test_a_cap_of_zero_sets_up_no_trace_at_all
    Evaluator.max_records = 0
    created = 0
    original = TracePoint.method(:new)
    TracePoint.stub(:new, ->(*args, &block) { created += 1; original.call(*args, &block) }) do
      assert_equal 3, Evaluator.evaluate('1 + 2', Evaluator.new_binding).value
    end
    assert_equal 0, created, 'no TracePoint was created'
  end

  def test_with_recording_off_errors_are_still_reported_without_variables
    Evaluator.max_records = 0
    result = Evaluator.evaluate(FAILS, Evaluator.new_binding)
    refute result.ok
    assert_kind_of KeyError, result.error
    assert_nil result.failure.binding
    assert_match(/KeyError/, Transcript.buffer)
    assert_equal 'rt_inner({})', result.failure.source.lines.last.strip, 'Run Again still has what to run'
  end

  def test_the_debugger_opens_with_recording_off
    Evaluator.max_records = 0
    GUI.reset_layout_state
    saved = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    ENV['HOME'] = @dir
    ENV['XDG_CONFIG_HOME'] = nil
    result = Evaluator.evaluate(FAILS, Evaluator.new_binding)
    GUI.notify_error(result.error, result.failure)
    assert_instance_of GUI::Debugger, GUI.windows.last
  ensure
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = saved
  end

  def test_max_records_must_be_a_whole_number
    ['10', -1, 2.5, nil].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { Evaluator.max_records = bad }
    end
    Evaluator.max_records = 7
    assert_equal 7, Evaluator.max_records
  end

  # --- syntax_error ----------------------------------------------------------------------------

  def test_syntax_error_by_the_compiler_when_there_is_one
    assert_nil Source.syntax_error('def a; end')
    error = Source.syntax_error("def a\n", 'accept')
    assert_kind_of SyntaxError, error
    assert_match(/accept:/, error.message)
  end

  def test_the_ripper_check_finds_ordinary_syntax_errors
    assert_nil Source.parse_error('def a; end')
    error = Source.parse_error("x = 1\ndef a\n  1 +\n", 'pane')
    assert_kind_of SyntaxError, error
    assert_match(/\Apane:\d+: .*unexpected end-of-input/, error.message)
    assert_match(/Can't change the value of self/, Source.parse_error('self = 1').message)
    assert_kind_of SyntaxError, Source.parse_error('foo(')
  end

  def test_syntax_error_falls_back_to_ripper_without_the_compiler
    Source.stub(:defined_compiler?, false) { nil } if Source.respond_to?(:defined_compiler?)
    hide = Object.const_get(:RubyVM)
    Object.send(:remove_const, :RubyVM)
    begin
      assert_nil Source.syntax_error('def a; end')
      error = Source.syntax_error("def a\n", 'accept')
      assert_kind_of SyntaxError, error
      assert_match(/accept:/, error.message)
    ensure
      Object.const_set(:RubyVM, hide)
    end
  end

  def test_compiler_only_errors_are_still_caught_on_cruby
    skip 'not CRuby' unless defined?(RubyVM::InstructionSequence)
    assert_kind_of SyntaxError, Source.syntax_error('def a(x, x); end'), 'a repeated parameter is a compile-time error'
  end

  def test_accept_refuses_a_syntax_error_before_evaluating_anything
    outcome = Compiler.accept("class RtParse1\nend\ndef broken\n", changes: RubyTalk.changes)
    refute outcome.ok
    assert_match(/SyntaxError/, outcome.message)
    refute Object.const_defined?(:RtParse1), 'nothing was evaluated'
  end
end
