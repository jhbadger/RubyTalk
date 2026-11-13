# frozen_string_literal: true

# `rubytalk --selftest` run against the fake tk: verifies the self-test's own logic.
#   ruby test/test_gui_selftest.rb

require_relative 'support/gui_case'

# The built-in `rubytalk --selftest` checks, run against the fake tk. This
# verifies the self-test's own logic; the real run on actual Tk is up to the user.
class SelfTestAgainstFakeTest < Minitest::Test
  include RubyTalk

  def test_selftest_passes_against_fake_tk
    dir = Dir.mktmpdir('rubytalk-selftest-test')
    RubyTalk.changes = ChangeSet.new(File.join(dir, 'changes.rb'))
    RubyTalk.changes.autosave = true
    main = GUI::MainWindow.new
    GUI.set_window_icon # GUI.start does these before the self-test runs
    Evaluator.driver = GUI::EventPump
    GUI.start_main_queue_timer
    failures = nil
    out, = capture_io { Timeout.timeout(60) { failures = GUI::SelfTest.new(main).run } }
    assert_equal 0, failures, out
    assert_match(/\d+ passed, 0 failed/, out)
    assert_equal GUI::SelfTest::CHECKS.size, out.scan(/^  PASS/).size
  ensure
    Evaluator.driver = nil
    FileUtils.remove_entry(dir) if dir
    Object.send(:remove_const, :RtSelfTest) if defined?(RtSelfTest)
  end
end
