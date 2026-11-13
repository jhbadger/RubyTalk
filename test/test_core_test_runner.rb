# frozen_string_literal: true

# Running Minitest classes made in RubyTalk.
#   ruby test/test_core_test_runner.rb

require_relative 'support/core_case'

class CoreTestRunnerTest < CoreCase
  def sample_tests
    RubyTalk::TestRunner.load_minitest
    accept("class RtCalc\nend\n")
    accept("def double(x)\n  x * 2\nend\n", klass: RtCalc)
    accept("class RtCalcTest < Minitest::Test\nend\n")
    {
      'test_double' => "assert_equal 4, RtCalc.new.double(2)",
      'test_wrong' => "assert_equal 5, RtCalc.new.double(2)",
      'test_error' => "RtCalc.new.nope",
      'test_skipped' => "skip 'later'",
      'test_prints' => "puts 'hello from a test'"
    }.each { |name, body| accept("def #{name}\n  #{body}\nend\n", klass: RtCalcTest) }
  end

  def drop_sample_tests
    %i[RtCalcTest RtCalc RtOtherTest RtSpecified TestRtSpecified RtSpecifiedSpec].each do |name|
      next unless Object.const_defined?(name)

      RubyTalk::TestRunner.forget(Object.const_get(name))
      Object.send(:remove_const, name)
    end
  end

  # Stand-ins for the two Minitest APIs (the sandbox only has Minitest 5; the user's Ruby 4.0.9 has 6.0.0).
  def fake_runnable(style, calls)
    Class.new do
      define_singleton_method(:name) { 'RtFakeRunnable' }
      define_singleton_method(:to_s) { 'RtFakeRunnable' }
      define_singleton_method(:runnable_methods) { %w[test_a test_b test_c] }
      if style == :minitest6
        # Minitest 6: Runnable.run(klass, method_name, reporter) runs ONE method.
        define_singleton_method(:run) { |klass, name, _reporter| calls << [:run, name] }
      else
        # Minitest 5: run(reporter, options) runs a class; run_one_method(klass, name, reporter) one method.
        define_singleton_method(:run) { |_reporter, _options = {}| raise 'a whole-class run must not be used' }
        define_singleton_method(:run_one_method) { |klass, name, _reporter| calls << [:run_one_method, name] }
      end
    end
  end

  # --- Test runner ---------------------------------------------------------



  def test_test_classes_are_found_by_name
    sample_tests
    assert_equal [RtCalcTest], RubyTalk::TestRunner.test_classes_for(RtCalc)
    assert_equal [RtCalcTest], RubyTalk::TestRunner.test_classes_for(RtCalcTest), 'a test class runs itself'
    assert_empty RubyTalk::TestRunner.test_classes_for(String)
    accept("class RtSpecified\nend\n")
    accept("class TestRtSpecified < Minitest::Test\nend\n")
    accept("class RtSpecifiedSpec < Minitest::Test\nend\n")
    names = RubyTalk::TestRunner.test_classes_for(RtSpecified).map(&:name)
    assert_equal %w[RtSpecifiedSpec TestRtSpecified], names.sort
  ensure
    drop_sample_tests
  end

  def test_test_classes_are_found_even_without_minitests_own_registry
    sample_tests
    Minitest::Runnable.stub(:runnables, []) do
      assert_equal [RtCalcTest], RubyTalk::TestRunner.test_classes_for(RtCalc), 'found by scanning for subclasses'
      assert_includes RubyTalk::TestRunner.user_test_classes(@changes), RtCalcTest
    end
    refute_includes RubyTalk::TestRunner.runnables, Class.new(Minitest::Test), 'anonymous classes are not listed'
  ensure
    drop_sample_tests
  end

  def test_running_tests_reports_every_kind_of_outcome
    sample_tests
    report = RubyTalk::Evaluator.with_transcript_io { RubyTalk::TestRunner.run([RtCalcTest]) }
    assert_equal({ pass: 2, fail: 1, error: 1, skip: 1 },
                 %i[pass fail error skip].to_h { |status| [status, report.count(status)] })
    refute report.green?
    assert_equal %w[RtCalcTest#test_error RtCalcTest#test_wrong], report.failures.map(&:label).sort
    assert_match(/5 tests, \d+ assertions, 1 failure, 1 error, 1 skip in \d+\.\d\ds/, report.summary)

    wrong = report.outcomes.find { |o| o.name == 'test_wrong' }
    assert_equal :fail, wrong.status
    assert_includes wrong.message, 'Expected: 5'
    assert_match(/rubytalk:RtCalcTest:2/, wrong.location)
    error = report.outcomes.find { |o| o.name == 'test_error' }
    assert_equal :error, error.status
    assert_match(/NoMethodError/, error.message)
    assert_equal 'later', report.outcomes.find { |o| o.name == 'test_skipped' }.message
    assert_includes Transcript.buffer, 'hello from a test', 'output printed by a test goes to the Transcript'
  ensure
    drop_sample_tests
  end


  def test_each_minitest_api_style_is_driven_correctly
    [[:minitest6, :run], [:minitest5, :run_one_method]].each do |style, expected|
      calls = []
      klass = fake_runnable(style, calls)
      RubyTalk::TestRunner.run([klass])
      assert_equal [[expected, 'test_a'], [expected, 'test_b'], [expected, 'test_c']], calls, style.to_s

      calls.clear
      RubyTalk::TestRunner.run([klass], filter: 'test_b')
      assert_equal [[expected, 'test_b']], calls, "#{style}: exact name"
      calls.clear
      RubyTalk::TestRunner.run([klass], filter: /\Atest_[ac]\z/)
      assert_equal %w[test_a test_c], calls.map(&:last), "#{style}: Regexp"
      calls.clear
      RubyTalk::TestRunner.run([klass], filter: '/test_[bc]/')
      assert_equal %w[test_b test_c], calls.map(&:last), "#{style}: /pattern/ string"
      calls.clear
      RubyTalk::TestRunner.run([klass], filter: 'RtFakeRunnable#test_c')
      assert_equal %w[test_c], calls.map(&:last), "#{style}: Class#method"
    end
  end

  def test_an_abstract_runnable_has_nothing_to_run
    klass = Class.new { define_singleton_method(:runnable_methods) { raise NotImplementedError } }
    report = RubyTalk::TestRunner.run([klass])
    assert_empty report.outcomes
  end

  def test_running_one_test_by_name_is_green
    sample_tests
    report = RubyTalk::Evaluator.with_transcript_io { RubyTalk::TestRunner.run([RtCalcTest], filter: 'test_double') }
    assert_equal ['test_double'], report.outcomes.map(&:name)
    assert report.green?
    assert_match(/\A1 test, 1 assertion, 0 failures, 0 errors, 0 skips in /, report.summary)
    only_failures = RubyTalk::TestRunner.run([RtCalcTest], filter: /\Atest_(wrong|error)\z/)
    assert_equal %w[test_error test_wrong], only_failures.outcomes.map(&:name).sort
  ensure
    drop_sample_tests
  end

  def test_user_test_classes_are_only_those_created_here
    sample_tests
    assert_includes RubyTalk::TestRunner.user_test_classes(@changes), RtCalcTest
    refute(RubyTalk::TestRunner.user_test_classes(@changes).any? { |klass| klass.name.start_with?('Minitest') })
  ensure
    drop_sample_tests
  end

  def test_removing_a_test_class_takes_it_out_of_minitest
    sample_tests
    klass = RtCalcTest
    assert_includes Minitest::Runnable.runnables, klass
    RubyTalk::Compiler.remove_class(klass, @changes)
    refute_includes Minitest::Runnable.runnables, klass
  ensure
    drop_sample_tests
  end

  def test_runner_without_minitest_says_so
    RubyTalk::TestRunner.stub(:load_minitest, false) do
      error = assert_raises(RubyTalk::TestRunner::Error) { RubyTalk::TestRunner.run([]) }
      assert_match(/not installed/, error.message)
    end
  end

  def test_test_class_template
    text = RubyTalk::Reflection.test_class_template('RtThing')
    assert_equal "# Tests for RtThing.\nclass RtThingTest < Minitest::Test\n  def test_something\n    assert true\n  end\nend\n", text
    assert RubyTalk::Source.syntax_error(text).nil?
  end
end
