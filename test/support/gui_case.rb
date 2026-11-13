# frozen_string_literal: true

# Shared setup for the GUI tests (test_gui_*.rb). They run against a recording stand-in for the
# tk gem (test/fake/tk.rb): they exercise RubyTalk's own GUI logic and cannot validate real Tk
# behaviour (that is what `rubytalk --selftest` is for).

$LOAD_PATH.unshift(File.expand_path('../fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'timeout'
require 'tmpdir'
require 'rubytalk'
require 'rubytalk/gui'
class GuiCase < Minitest::Test
  include RubyTalk

  def setup
    @saved_home = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk-gui')
    RubyTalk.changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
    # Settings (last folder, window layout) go to a temporary home, never the real one.
    ENV['HOME'] = @dir
    ENV['XDG_CONFIG_HOME'] = nil
    GUI.reset_layout_state
  end

  def teardown
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = @saved_home
    Tk.screen_width = nil
    Tk.screen_height = nil
    Evaluator.driver = nil
    Tk.update_hook = nil
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :RtGuiThing) if defined?(RtGuiThing)
    String.send(:remove_method, :rt_gui) if String.method_defined?(:rt_gui)
  end

  def ivar(object, name)
    object.instance_variable_get(name)
  end

  def change_directory_with(answer, confirm: 'yes')
    Tk.chooser_answer = answer
    Tk.message_answer = confirm
    restarted = nil
    RubyTalk.stub(:restart_in, ->(dir) { restarted = dir }) { GUI.change_directory }
    restarted
  ensure
    Tk.message_answer = nil
  end

  def press(win, event, x, y)
    tk('event', 'generate', win.canvas.path, "<#{event}>", '-x', x.to_s, '-y', y.to_s)
  end

  # Tk calls with unfrozen strings (this file's literals are frozen, and the tk gem mutates its arguments).
  def tk(*args)
    Tk.tk_call(*args.map { |arg| arg.is_a?(String) ? arg.dup : arg })
  end

  def with_pump
    Evaluator.driver = GUI::EventPump
    Timeout.timeout(10) { yield }
  ensure
    Evaluator.driver = nil
    Tk.update_hook = nil
  end

  def with_home(home)
    saved = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    ENV['HOME'] = home
    ENV['XDG_CONFIG_HOME'] = nil
    yield
  ensure
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = saved
  end
end
