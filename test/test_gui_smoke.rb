# frozen_string_literal: true

# Smoke test for the Tk layer against a recording stand-in for the tk gem
# (test/fake/tk.rb). Run:  ruby test/test_gui_smoke.rb
# This exercises RubyTalk's own GUI logic; it cannot validate real Tk behaviour.

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'rubytalk'
require 'rubytalk/gui'

class GuiSmokeTest < Minitest::Test
  include RubyTalk

  def setup
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk-gui')
    RubyTalk.changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :RtGuiThing) if defined?(RtGuiThing)
    String.send(:remove_method, :rt_gui) if String.method_defined?(:rt_gui)
  end

  def ivar(object, name)
    object.instance_variable_get(name)
  end

  def test_start_opens_transcript_browser_and_workspace
    GUI.start
    assert_equal [GUI::MainWindow, GUI::Browser, GUI::Workspace], GUI.windows.last(3).map(&:class)
  end

  def test_method_list_accept_recompiles_in_place
    Compiler.accept("class RtMl\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def v\n  1\nend\n", klass: RtMl, changes: RubyTalk.changes)
    GUI.show_method_list(:implementors, 'v')
    list = GUI.windows.last
    assert_instance_of GUI::MethodList, list
    index = ivar(list, :@hits).index { |hit| hit.label == 'RtMl#v' }
    ivar(list, :@list).box.click(index)
    assert_equal "def v\n  1\nend\n", list.code.contents
    list.code.set_contents("def v\n  2\nend\n")
    list.code.accept
    assert_equal 2, RtMl.new.v
  ensure
    Object.send(:remove_const, :RtMl) if defined?(RtMl)
  end

  def test_main_window_shows_transcript_and_banner
    main = GUI::MainWindow.new
    text = main.editor.text
    assert_includes text.content, "RubyTalk #{RubyTalk::VERSION}"
    Transcript.show_cr('later output')
    assert_includes text.content, 'later output'
    Transcript.clear
    assert_equal '', text.content
  end

  def test_workspace_do_it_print_it_and_temporaries
    ws = GUI::Workspace.new(text: '3 + 4')
    editor = ws.editor
    editor.print_it
    assert_equal '3 + 4 7', editor.contents

    ws2 = GUI::Workspace.new(text: 'x = 5')
    ws2.editor.do_it
    ws2.editor.set_contents('x * 3')
    ws2.editor.print_it
    assert_equal 'x * 3 15', ws2.editor.contents
  end

  def test_do_it_uses_selection_and_writes_to_transcript
    ws = GUI::Workspace.new(text: "puts 'ignored'\nTranscript.show_cr 'picked'")
    ws.editor.text.select_text("Transcript.show_cr 'picked'")
    ws.editor.do_it
    assert_equal "picked\n", Transcript.buffer
    ws.editor.set_contents("puts 'line one'")
    ws.editor.do_it
    assert_includes Transcript.buffer, 'line one'
  end

  def test_key_bindings_run_and_break
    ws = GUI::Workspace.new(text: '6 * 7')
    result = ws.editor.text.fire("#{GUI::MODIFIER}-Key-p")
    assert_equal :break, result
    assert_equal '6 * 7 42', ws.editor.contents
  end

  def test_error_opens_notifier_and_keeps_going
    ws = GUI::Workspace.new(text: '1 / 0')
    before = GUI.windows.size
    ws.editor.do_it
    assert_operator GUI.windows.size, :>, before
    assert_instance_of GUI::ErrorWindow, GUI.windows.last
    assert_match(/ZeroDivisionError/, Transcript.buffer)
  end

  def test_inspect_it_opens_inspector
    ws = GUI::Workspace.new(text: '[10, 20, {a: 1}]')
    ws.editor.inspect_it
    inspector = GUI.windows.last
    assert_instance_of GUI::Inspector, inspector
    list = ivar(inspector, :@list)
    labels = list.box.items
    assert_equal ['self', '[0]', '[1]', '[2]'], labels
    list.box.click(1)
    assert_equal '10', ivar(inspector, :@value).contents
  end

  def test_inspector_shows_instance_variables_and_evaluates_in_self
    object = Struct.new(:a).new(1)
    object.instance_variable_set(:@extra, 'x')
    inspector = GUI::Inspector.new(object)
    labels = ivar(inspector, :@list).box.items
    assert_includes labels, '@extra'
    assert_includes labels, 'a'
    console = ivar(inspector, :@console)
    console.set_contents('a + 41')
    console.print_it
    assert_equal 'a + 41 42', console.contents
  end

  def test_browser_navigation_shows_definition_template_and_source
    browser = GUI::Browser.new(String)
    code = browser.code
    assert_match(/\Aclass String < Object/, code.contents)

    protocols = ivar(browser, :@protocols)
    assert_equal ['-- all --', 'public', 'protected', 'private'], protocols.box.items

    protocols.box.click(0)
    assert_equal Reflection.method_template, code.contents
    methods = ivar(browser, :@methods)
    assert_includes methods.box.items, 'upcase'

    methods.box.click(methods.box.items.index('upcase'))
    assert_match(/implemented in C/, code.contents)
  end

  def test_browser_accept_creates_class_and_methods_and_logs_them
    browser = GUI::Browser.new
    categories = ivar(browser, :@categories)
    categories.box.click(categories.box.items.index('User-Defined'))
    code = browser.code
    assert_equal Reflection.new_class_template, code.contents

    code.set_contents("class RtGuiThing < Object\nend\n")
    code.accept
    assert defined?(RtGuiThing)
    assert_equal 1, RubyTalk.changes.entries.size
    assert_match(/class RtGuiThing/, code.contents)

    ivar(browser, :@protocols).box.click(0)
    code.set_contents("def hi\n  :hi\nend\n")
    code.accept
    assert_equal :hi, RtGuiThing.new.hi
    assert_equal "def hi\n  :hi\nend\n", code.contents, 'accepted method is selected and shown'
    assert_equal %w[* hi].join(' '), ivar(browser, :@methods).box.items.first

    # class side
    ivar(browser, :@side_var).value = +'class'
    browser.send(:side_changed)
    code.set_contents("def build\n  new\nend\n")
    code.accept
    assert_instance_of RtGuiThing, RtGuiThing.build
    assert_equal :class, RubyTalk.changes.entries.last.side

    # redefine, then remove
    ivar(browser, :@side_var).value = +'instance'
    browser.send(:side_changed)
    code.set_contents("def hi\n  :hello\nend\n")
    code.accept
    assert_equal :hello, RtGuiThing.new.hi
    browser.send(:remove_method)
    refute RtGuiThing.method_defined?(:hi)
    assert(RubyTalk.changes.entries.any? { |e| e.kind == :remove_method })
  end

  def test_browser_accept_error_is_reported_not_raised
    browser = GUI::Browser.new(String)
    code = browser.code
    code.set_contents('def oops(')
    code.accept
    status = ivar(browser, :@status).options[:text]
    assert_match(/Not accepted: SyntaxError/, status)
    assert_empty RubyTalk.changes.entries
  end

  def test_browser_extends_builtin_class
    browser = GUI::Browser.new(String)
    ivar(browser, :@protocols).box.click(0)
    browser.code.set_contents("def rt_gui\n  :ok\nend\n")
    browser.code.accept
    assert_equal :ok, 'x'.rt_gui
    assert_equal 'String', RubyTalk.changes.entries.last.target
  end

  def test_browse_it_opens_browser_on_class_of_value
    ws = GUI::Workspace.new(text: '"text"')
    ws.editor.browse_it
    browser = GUI.windows.last
    assert_instance_of GUI::Browser, browser
    assert_match(/\Aclass String/, browser.code.contents)
  end

  def test_menus_are_built_and_work
    ws = GUI::Workspace.new(text: '2 + 2')
    root_menu = ws.instance_variable_get(:@window).options[:menu]
    assert_instance_of TkMenu, root_menu
    assert_equal %w[System Edit], root_menu.entries.map { |_, o| o[:label] }
    edit = root_menu.entries.last[1][:menu]
    edit.invoke('Print it')
    assert_equal '2 + 2 4', ws.editor.contents
    system_menu = root_menu.entries.first[1][:menu]
    system_menu.invoke('Open Workspace')
    assert_instance_of GUI::Workspace, GUI.windows.last
  end

  def test_save_changes_menu_item_and_exit_save
    RubyTalk.changes.record(kind: :class, target: 'RtGuiThing', source: "class RtGuiThing\nend\n", created: true)
    assert_equal File.join(@dir, 'changes.rb'), RubyTalk.save_changes
    assert File.file?(File.join(@dir, 'changes.rb'))
    assert_nil RubyTalk.save_changes
  end
end

# The built-in `rubytalk --selftest` checks, run against the fake tk. This
# verifies the self-test's own logic; the real run on actual Tk is up to the user.
class SelfTestAgainstFakeTest < Minitest::Test
  include RubyTalk

  def test_selftest_passes_against_fake_tk
    dir = Dir.mktmpdir('rubytalk-selftest-test')
    RubyTalk.changes = ChangeSet.new(File.join(dir, 'changes.rb'))
    RubyTalk.changes.autosave = true
    main = GUI::MainWindow.new
    failures = nil
    out, = capture_io { failures = GUI::SelfTest.new(main).run }
    assert_equal 0, failures, out
    assert_match(/\d+ passed, 0 failed/, out)
    assert_equal GUI::SelfTest::CHECKS.size, out.scan(/^  PASS/).size
  ensure
    FileUtils.remove_entry(dir) if dir
    Object.send(:remove_const, :RtSelfTest) if defined?(RtSelfTest)
  end
end
