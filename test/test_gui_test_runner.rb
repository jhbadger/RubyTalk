# frozen_string_literal: true

# The test results window and running tests from the Browser.
#   ruby test/test_gui_test_runner.rb

require_relative 'support/gui_case'

class GuiTestRunnerTest < GuiCase
  def runner_fixture(passing_only: false)
    TestRunner.load_minitest
    changes = RubyTalk.changes
    Compiler.accept("class RtGc\nend\n", changes: changes)
    Compiler.accept("def double(x)\n  x * 2\nend\n", klass: RtGc, changes: changes)
    Compiler.accept("class RtGcTest < Minitest::Test\nend\n", changes: changes)
    tests = { 'test_ok' => 'assert_equal 4, RtGc.new.double(2)' }
    tests.merge!('test_wrong' => 'assert_equal 5, RtGc.new.double(2)', 'test_boom' => 'RtGc.new.nope') unless passing_only
    tests.each { |name, body| Compiler.accept("def #{name}\n  #{body}\nend\n", klass: RtGcTest, changes: changes) }
  end

  def drop_runner_fixture
    %i[RtGcTest RtGc].each do |name|
      next unless Object.const_defined?(name)

      TestRunner.forget(Object.const_get(name))
      Object.send(:remove_const, name)
    end
  end

  # --- test runner -------------------------------------------------------



  def test_running_tests_shows_a_red_bar_and_the_failures_first
    runner_fixture
    GUI.run_tests_for(RtGc)
    window = GUI.windows.last
    assert_instance_of GUI::TestResultsWindow, window
    bar = ivar(window, :@bar)
    assert_equal '2 of 3 tests failed', bar.options[:text]
    assert_equal GUI::TestResultsWindow::RED, bar.options[:background]
    list = ivar(window, :@list)
    assert_match(/\AERROR  RtGcTest#test_boom/, list.box.items[0])
    assert_match(/\AFAIL   RtGcTest#test_wrong/, list.box.items[1])
    assert_match(/\APASS   RtGcTest#test_ok/, list.box.items[2])
    detail = ivar(window, :@detail).get('1.0', 'end-1c')
    assert_match(/NoMethodError/, detail, 'the first failure is selected and explained')
    list.box.click(1)
    assert_match(/Expected: 5/, ivar(window, :@detail).get('1.0', 'end-1c'))
    assert_match(/rubytalk:RtGcTest:2/, ivar(window, :@detail).get('1.0', 'end-1c'))
    list.box.click(2)
    assert_match(/\APassed in /, ivar(window, :@detail).get('1.0', 'end-1c'))
  ensure
    drop_runner_fixture
  end

  def test_a_run_that_cannot_be_made_opens_the_debugger_not_a_silent_failure
    runner_fixture
    windows = GUI.windows.size
    TestRunner.stub(:run, ->(*) { raise 'the runner broke' }) { GUI.run_tests_for(RtGc) }
    assert_instance_of GUI::Debugger, GUI.windows.last
    assert_equal windows + 1, GUI.windows.size
    assert_match(/the runner broke/, Transcript.buffer)
  ensure
    drop_runner_fixture
  end

  def test_a_missing_minitest_is_explained_in_the_transcript_only
    runner_fixture
    windows = GUI.windows.size
    TestRunner.stub(:run, ->(*) { raise TestRunner::Error, 'Minitest is not installed (gem install minitest).' }) do
      GUI.run_tests_for(RtGc)
    end
    assert_equal windows, GUI.windows.size
    assert_match(/Minitest is not installed/, Transcript.buffer)
  ensure
    drop_runner_fixture
  end

  def test_selftest_failures_show_what_the_transcript_said
    main = GUI::MainWindow.new
    selftest = GUI::SelfTest.new(main)
    Transcript.show_cr('the real reason it failed')
    selftest.send(:run_check, :no_such_check)
    out, = capture_io { selftest.send(:report) }
    assert_match(/FAIL  no_such_check/, out)
    assert_match(/transcript: the real reason it failed/, out)
  end

  def test_all_green_shows_a_green_bar
    runner_fixture(passing_only: true)
    GUI.run_tests_for(RtGc)
    bar = ivar(GUI.windows.last, :@bar)
    assert_equal 'All 1 test passed', bar.options[:text]
    assert_equal GUI::TestResultsWindow::GREEN, bar.options[:background]
  ensure
    drop_runner_fixture
  end

  def test_run_failures_and_run_again
    runner_fixture
    GUI.run_tests_for(RtGc)
    window = GUI.windows.last
    window.send(:run_failures)
    assert_equal 2, ivar(window, :@list).box.items.size, 'only the tests that failed'
    window.send(:run_again)
    assert_equal 3, ivar(window, :@list).box.items.size, 'run again repeats the whole run'
    # fix the broken tests in place, then run the failures again: the bar turns green
    Compiler.accept("def test_wrong\n  assert_equal 4, RtGc.new.double(2)\nend\n", klass: RtGcTest, changes: RubyTalk.changes)
    Compiler.accept("def test_boom\n  assert true\nend\n", klass: RtGcTest, changes: RubyTalk.changes)
    window.send(:run_again)
    assert_equal 'All 3 tests passed', ivar(window, :@bar).options[:text]
    window.send(:run_failures)
    assert_equal 'Nothing failed.', ivar(window, :@status).options[:text]
  ensure
    drop_runner_fixture
  end

  def test_edit_test_opens_it_in_the_browser
    runner_fixture
    GUI.run_tests_for(RtGc)
    window = GUI.windows.last
    ivar(window, :@list).box.click(1) # test_wrong
    window.send(:edit_test)
    browser = GUI.windows.last
    assert_instance_of GUI::Browser, browser
    assert_equal "def test_wrong\n  assert_equal 5, RtGc.new.double(2)\nend\n", browser.code.contents
  ensure
    drop_runner_fixture
  end

  def test_no_tests_found_says_how_to_make_some
    windows = GUI.windows.size
    GUI.run_tests_for(String)
    assert_equal windows, GUI.windows.size
    assert_match(/No tests found for String\. Define a Minitest class named StringTest/, Transcript.buffer)
    Transcript.clear
    GUI.run_all_user_tests
    assert_match(/No test classes have been created/, Transcript.buffer)
  end

  def test_tests_run_on_the_worker_thread_when_the_ui_is_live
    runner_fixture
    with_pump do
      GUI.run_tests_for(RtGc)
      assert_instance_of GUI::TestResultsWindow, GUI.windows.last
      assert_equal 3, ivar(GUI.windows.last, :@list).box.items.size
    end
  ensure
    drop_runner_fixture
  end

  def test_browser_runs_tests_and_makes_test_classes
    runner_fixture
    browser = GUI::Browser.open(RtGc)
    browser.send(:run_class_tests)
    assert_instance_of GUI::TestResultsWindow, GUI.windows.last

    browser = GUI::Browser.open(RtGcTest)
    ivar(browser, :@protocols).box.click(0)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(:test_wrong))
    browser.send(:run_test)
    assert_equal ['RtGcTest#test_wrong'], ivar(GUI.windows.last, :@report).outcomes.map(&:label)
    assert_equal 'RtGcTest#test_wrong', ivar(GUI.windows.last, :@report).outcomes.first.label

    methods.box.click(ivar(methods, :@values).index(:test_ok))
    browser.send(:run_test)
    assert ivar(GUI.windows.last, :@report).green?

    plain = GUI::Browser.open(RtGc)
    plain.send(:new_test_class)
    assert_equal Reflection.test_class_template('RtGc'), plain.code.contents
    ivar(plain, :@protocols).box.click(0)
    ivar(plain, :@methods).box.click(ivar(ivar(plain, :@methods), :@values).index(:double))
    plain.send(:run_test)
    assert_match(/Select a method whose name starts with test/, ivar(plain, :@status).options[:text])
  ensure
    drop_runner_fixture
  end

  def test_system_menu_runs_all_user_tests
    runner_fixture(passing_only: true)
    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    system_menu = menubar.entries.first[1][:menu]
    system_menu.invoke('Run All User Tests')
    window = GUI.windows.last
    assert_instance_of GUI::TestResultsWindow, window
    assert_equal 'All 1 test passed', ivar(window, :@bar).options[:text]
  ensure
    drop_runner_fixture
  end
end
