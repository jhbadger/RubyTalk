# frozen_string_literal: true

# Smoke test for the Tk layer against a recording stand-in for the tk gem
# (test/fake/tk.rb). Run:  ruby test/test_gui_smoke.rb
# This exercises RubyTalk's own GUI logic; it cannot validate real Tk behaviour.

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'timeout'
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
    Evaluator.driver = nil
    Tk.update_hook = nil
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
    assert GUI.icon_image, 'the window/Dock icon is set at startup'
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

  def change_directory_with(answer, confirm: 'yes')
    Tk.chooser_answer = answer
    Tk.message_answer = confirm
    restarted = nil
    RubyTalk.stub(:restart_in, ->(dir) { restarted = dir }) { GUI.change_directory }
    restarted
  ensure
    Tk.message_answer = nil
  end

  def test_change_directory_restarts_in_the_chosen_folder
    target = File.join(@dir, 'other')
    Tk.chooser_requests.clear
    assert_equal target, change_directory_with(target)
    assert File.directory?(target)
    assert_equal @dir, Tk.chooser_requests.last[1], 'the chooser starts in the current folder'
    assert_match(/Could not restart automatically/, Transcript.buffer, 'reported when the restart returns')
  end

  def test_change_directory_does_nothing_on_cancel_same_folder_or_decline
    assert_nil change_directory_with(''), 'Cancel'
    assert_nil change_directory_with(@dir), 'the folder already in use'
    other = File.join(@dir, 'declined')
    assert_nil change_directory_with(other, confirm: 'no')
    refute File.exist?(other)
  end

  def test_run_remembers_the_folder_for_next_time
    with_home(@dir) do
      folder = File.join(@dir, 'remembered')
      FileUtils.mkdir_p(folder)
      RubyTalk.run(dir: folder)
      assert_equal folder, Preferences.last_directory
      assert_equal File.join(folder, 'changes.rb'), RubyTalk.changes.path
    end
  end

  def test_code_panes_are_highlighted_and_the_transcript_is_not
    workspace = GUI::Workspace.new(text: "def foo; :sym; end # c")
    text = workspace.editor.text
    tags_at = ->(index) { text.tag_command(['names', index]).split }
    assert_includes tags_at.call('1.0'), 'rt_keyword'
    assert_includes tags_at.call('1.4'), 'rt_def_name'
    assert_includes tags_at.call('1.9'), 'rt_symbol'
    assert_includes tags_at.call('1.20'), 'rt_comment'

    workspace.editor.set_contents('x = 1')
    assert_includes tags_at.call('1.4'), 'rt_number'
    refute_includes tags_at.call('1.0'), 'rt_keyword', 'old colours are cleared'

    main = GUI::MainWindow.new
    main.editor.set_contents('def foo; end')
    assert_empty main.editor.text.tag_store, 'the Transcript is output, not code: no highlighting'
  end

  def test_highlighting_follows_typing_and_print_it
    editor = GUI::Workspace.new(text: '1 + 1').editor
    editor.print_it
    assert_includes editor.text.tag_command(['names', '1.0']).split, 'rt_number'
    editor.text.insert('end', +' # typed')
    editor.text.fire('KeyRelease')
    assert_includes editor.text.tag_command(['names', '1.8']).split, 'rt_comment'
  end

  def test_palette_follows_the_background_colour
    Tk.rgb_answer = '0 0 0'
    dark = GUI::Workspace.new(text: 'x').editor
    assert_equal RubyTalk::Highlighter::PALETTES[:dark][:keyword], dark.text.tag_options['rt_keyword']['-foreground']
    Tk.rgb_answer = '65535 65535 65535'
    light = GUI::Workspace.new(text: 'x').editor
    assert_equal RubyTalk::Highlighter::PALETTES[:light][:keyword], light.text.tag_options['rt_keyword']['-foreground']
  ensure
    Tk.rgb_answer = nil
  end

  # --- debugger ----------------------------------------------------------

  def debugger_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtDbgW\nend\n", changes: changes)
    Compiler.accept("def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", klass: RtDbgW, changes: changes)
    GUI::Workspace.new(text: 'RtDbgW.new.explode(21)').editor.do_it
    GUI.windows.last
  end

  def test_debugger_shows_stack_source_locals_and_evaluates_in_the_frame
    debugger = debugger_fixture
    assert_instance_of GUI::Debugger, debugger
    assert_match(/rubytalk:RtDbgW:3/, ivar(debugger, :@stack).box.items.first)
    assert_equal "def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", debugger.source.contents
    assert_includes debugger.source.text.tag_command(['names', '3.0']).split, 'rt_current_line', 'the failing line is marked'
    refute_includes debugger.source.text.tag_command(['names', '1.0']).split, 'rt_current_line'

    rows = ivar(debugger, :@variables).box.items
    assert(rows.any? { |row| row.start_with?('local = 42') }, rows.inspect)
    assert(rows.any? { |row| row.start_with?('n = 21') })

    debugger.console.set_contents('local + 1')
    debugger.console.print_it
    assert_equal 'local + 1 43', debugger.console.contents, 'evaluated in the frame that raised'
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_outer_frames_have_source_but_no_locals
    debugger = debugger_fixture
    stack = ivar(debugger, :@stack)
    outer = stack.box.items.index { |item| item.include?('workspace:1') }
    refute_nil outer
    stack.box.click(outer)
    assert_equal "RtDbgW.new.explode(21)", debugger.source.contents
    assert_empty ivar(debugger, :@variables).box.items
    assert_match(/only kept for the frame that raised/, ivar(debugger, :@status).options[:text])
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_edit_method_opens_the_browser_on_it
    debugger = debugger_fixture
    debugger.send(:edit_method)
    browser = GUI.windows.last
    assert_instance_of GUI::Browser, browser
    assert_equal "def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", browser.code.contents
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_inspects_a_variable
    debugger = debugger_fixture
    variables = ivar(debugger, :@variables)
    index = variables.box.items.index { |row| row.start_with?('local = ') }
    variables.box.click(index)
    debugger.send(:inspect_variable)
    assert_instance_of GUI::Inspector, GUI.windows.last
    assert_equal 42, ivar(GUI.windows.last, :@object)
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_run_again_after_a_fix
    $rt_flag = false
    editor = GUI::Workspace.new(text: "$rt_flag = !$rt_flag; raise 'first time' if $rt_flag; :fine").editor
    editor.do_it
    debugger = GUI.windows.last
    assert_instance_of GUI::Debugger, debugger
    debugger.send(:run_again)
    assert_match(/Run again: :fine/, Transcript.buffer)
  end

  def test_debugger_run_again_that_fails_again_opens_a_new_debugger
    $rt_runs = 0
    GUI::Workspace.new(text: "$rt_runs += 1; raise 'still broken'").editor.do_it
    first = GUI.windows.last
    first.send(:run_again)
    assert_equal 2, $rt_runs
    assert_instance_of GUI::Debugger, GUI.windows.last
    refute_same first, GUI.windows.last
  end

  def test_debugger_copes_with_an_error_that_has_no_stack
    debugger = GUI::Debugger.new(RuntimeError.new('no backtrace'))
    assert_match(/No stack is available/, debugger.source.contents)
    debugger.send(:edit_method) # nothing to edit: must not raise
    debugger.send(:run_again)
    assert_equal 'This cannot be run again.', ivar(debugger, :@status).options[:text]
  end

  # --- hierarchy ---------------------------------------------------------

  def test_hierarchy_browser_lists_the_hierarchy_and_works_like_a_browser
    Object.const_set(:RtHb1, Class.new)
    Object.const_set(:RtHb2, Class.new(RtHb1))
    browser = GUI::Browser.open(RtHb1, hierarchy: true)
    assert_equal ['Hierarchy of RtHb1'], ivar(browser, :@categories).box.items
    classes = ivar(browser, :@classes)
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2'], classes.box.items
    assert_equal "class RtHb1 < Object\nend\n", browser.code.contents, 'the class you asked about is selected'

    browser.code.set_contents("class RtHb3 < RtHb2\nend\n")
    browser.code.accept
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2', '        RtHb3'], classes.box.items,
                 'a new subclass joins the hierarchy and is selected'
    assert_match(/class RtHb3 < RtHb2/, browser.code.contents)

    ivar(classes, :@filter_var).value = +'hb2'
    browser.send(:refresh_classes)
    assert_equal ['      RtHb2'], classes.box.items, 'the filter box works on the hierarchy'
    ivar(classes, :@filter_var).value = +''
    browser.send(:refresh_classes)

    browser.send(:remove_class) # RtHb3 is still selected
    refute defined?(RtHb3)
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2'], classes.box.items
  ensure
    %i[RtHb3 RtHb2 RtHb1].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_hierarchy_opens_from_the_browser_and_from_an_editor
    browser = GUI::Browser.open(String)
    browser.send(:show_hierarchy)
    window = GUI.windows.last
    assert_equal String, ivar(window, :@hierarchy_root)
    assert_equal ['BasicObject', '  Object', '    String'], ivar(window, :@classes).box.items.first(3)

    GUI::Workspace.new(text: 'String').editor.hierarchy_of_it
    assert_equal String, ivar(GUI.windows.last, :@hierarchy_root)
    GUI::Workspace.new(text: '3').editor.hierarchy_of_it
    assert_equal Integer, ivar(GUI.windows.last, :@hierarchy_root), 'a non-class gives the hierarchy of its class'
  end

  def test_normal_browser_is_unaffected_by_hierarchy_mode
    browser = GUI::Browser.open(String)
    assert_nil ivar(browser, :@hierarchy_root)
    assert_includes ivar(browser, :@categories).box.items, 'Text'
    assert_includes ivar(browser, :@classes).box.items, 'String'
  end

  # --- versions ---------------------------------------------------------

  def versions_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtVw\nend\n", changes: changes)
    Compiler.accept("def v\n  1\nend\n", klass: RtVw, changes: changes)
    Compiler.accept("def v\n  2\nend\n", klass: RtVw, changes: changes)
  end

  def test_versions_window_lists_shows_diffs_and_reverts
    versions_fixture
    changed = 0
    window = GUI::VersionsWindow.new(RtVw, :instance, 'v', on_change: -> { changed += 1 })
    list = ivar(window, :@list)
    assert_equal 2, list.box.items.size
    assert_match(/\ACurrent - /, list.box.items.first)
    assert_equal "def v\n  2\nend\n", window.code.contents, 'the newest version is selected first'

    list.box.click(1)
    assert_equal "def v\n  1\nend\n", window.code.contents

    ivar(window, :@diff_var).value = +'1'
    window.send(:show, list.selected_value)
    assert_equal "  def v\n-   2\n+   1\n  end\n", window.code.contents, 'shows what reverting would change'
    tags_at = ->(index) { window.code.text.tag_command(['names', index]).split }
    assert_includes tags_at.call('2.0'), 'rt_diff_del'
    assert_includes tags_at.call('3.0'), 'rt_diff_add'
    refute_includes tags_at.call('1.0'), 'rt_diff_add'

    window.send(:revert)
    assert_equal 1, RtVw.new.v
    assert_equal 1, changed
    assert_match(/def v/, window.code.contents)
    assert_equal 3, ivar(window, :@list).box.items.size, 'the replaced version joins the history'
  ensure
    Object.send(:remove_const, :RtVw) if defined?(RtVw)
  end

  def test_versions_window_with_nothing_to_show
    window = GUI::VersionsWindow.new(String, :instance, 'upcase')
    assert_empty ivar(window, :@list).box.items
    assert_match(/No earlier versions/, window.code.contents)
    window.send(:revert) # must not raise
  end

  def test_browser_opens_versions_and_remove_restores_the_original
    Object.const_set(:RtLibB, Class.new { def old = :old })
    browser = GUI::Browser.new(RtLibB)
    ivar(browser, :@protocols).box.click(0)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(:old))
    browser.code.set_contents("def old\n  :changed\nend\n")
    browser.code.accept
    assert_equal :changed, RtLibB.new.old

    browser.send(:show_versions)
    assert_instance_of GUI::VersionsWindow, GUI.windows.last
    assert_equal 2, ivar(GUI.windows.last, :@list).box.items.size, 'current + original'

    browser.send(:remove_method)
    assert_equal :old, RtLibB.new.old
    assert_equal 'Restored the original method.', ivar(browser, :@status).options[:text]
    assert_match(/def old/, browser.code.contents)

    browser.code.set_contents("class RtMineB\n  def mine; end\nend\n")
    browser.code.accept
    ivar(browser, :@protocols).box.click(0)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(:mine))
    browser.send(:remove_method)
    refute RtMineB.method_defined?(:mine)
    assert_equal 'Method removed.', ivar(browser, :@status).options[:text]
  ensure
    %i[RtLibB RtMineB].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_method_list_opens_versions
    Compiler.accept("class RtMl2\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def v; 1; end\n", klass: RtMl2, changes: RubyTalk.changes)
    Compiler.accept("def v; 2; end\n", klass: RtMl2, changes: RubyTalk.changes)
    GUI.show_method_list(:implementors, 'v')
    list = GUI.windows.last
    index = ivar(list, :@hits).index { |hit| hit.label == 'RtMl2#v' }
    ivar(list, :@list).box.click(index)
    list.send(:versions)
    assert_instance_of GUI::VersionsWindow, GUI.windows.last
    assert_equal 2, ivar(GUI.windows.last, :@list).box.items.size
    ivar(GUI.windows.last, :@list).box.click(1) # the earlier version
    GUI.windows.last.send(:revert)
    assert_equal 1, RtMl2.new.v
    assert_equal "def v; 1; end\n", list.code.contents, 'the method list shows the reverted source'
  ensure
    Object.send(:remove_const, :RtMl2) if defined?(RtMl2)
  end

  # --- running code off the main thread (interrupt) ------------------------

  def with_pump
    Evaluator.driver = GUI::EventPump
    Timeout.timeout(10) { yield }
  ensure
    Evaluator.driver = nil
    Tk.update_hook = nil
  end

  def test_do_it_runs_off_the_main_thread_while_the_ui_keeps_updating
    with_pump do
      editor = GUI::Workspace.new(text: 'sleep 0.05; Thread.current == Thread.main').editor
      before = Tk.update_count
      editor.print_it
      assert_equal 'sleep 0.05; Thread.current == Thread.main false', editor.contents
      assert_operator Tk.update_count, :>, before, 'Tk events were processed while the code ran'
    end
  end

  def test_stop_key_interrupts_a_runaway_do_it
    with_pump do
      editor = GUI::Workspace.new(text: 'loop {}').editor
      pressed = false
      Tk.update_hook = lambda do
        next if pressed

        pressed = true
        editor.text.fire("#{GUI::MODIFIER}-Key-period")
      end
      windows = GUI.windows.size
      editor.do_it
      assert pressed
      assert_match(/Interrupting\.\.\./, Transcript.buffer)
      assert_match(/Interrupted\./, Transcript.buffer)
      assert_equal windows, GUI.windows.size, 'an interrupt does not open an error window'
      refute Evaluator.busy?
    end
  end

  def test_interrupt_menu_item_and_nothing_running
    GUI.interrupt
    assert_match(/Nothing is running/, Transcript.buffer)
    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    labels = menubar.entries.first[1][:menu].entries.map { |_, options| options[:label] }
    assert_includes labels, 'Interrupt Running Code'
  end

  def test_output_and_windows_from_the_worker_are_handed_to_the_main_thread
    with_pump do
      main = GUI::MainWindow.new
      code = "Transcript.show_cr 'from worker'; RubyTalk::GUI::Inspector.new([1, 2]); :done"
      GUI::Workspace.new(text: code).editor.do_it
      assert_includes main.editor.contents, 'from worker'
      assert_instance_of GUI::Inspector, GUI.windows.last
    end
  end

  def test_a_second_do_it_while_one_is_running_is_refused
    with_pump do
      editor = GUI::Workspace.new(text: 'sleep 0.05; :first').editor
      other = GUI::Workspace.new(text: ':second').editor
      Tk.update_hook = lambda do
        Tk.update_hook = nil
        other.do_it
      end
      editor.do_it
      assert_match(/Something is already running/, Transcript.buffer)
    end
  end

  def test_title_bar_shows_running_and_clears_afterwards
    with_pump do
      main = GUI::MainWindow.new
      during = nil
      Tk.update_hook = lambda do
        during ||= Tk.last_title
      end
      GUI::Workspace.new(text: 'sleep 0.05').editor.do_it
      assert_match(/running/, during)
      assert_equal main.send(:title), Tk.last_title
    end
  end

  def test_losing_the_window_while_code_runs_stops_the_code
    with_pump do
      editor = GUI::Workspace.new(text: 'sleep').editor
      Tk.update_hook = -> { raise 'the window is gone' }
      editor.do_it
      Tk.update_hook = nil
      refute Evaluator.busy?
    end
  end

  def test_idle_background_output_is_drained_by_the_timer
    main = GUI::MainWindow.new
    GUI.start_main_queue_timer
    Thread.new { Transcript.show_cr('late output') }.join
    refute_includes main.editor.contents, 'late output', 'queued, not yet on screen'
    TkTimer.all.last.fire
    assert_includes main.editor.contents, 'late output'
  end

  def with_home(home)
    saved = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    ENV['HOME'] = home
    ENV['XDG_CONFIG_HOME'] = nil
    yield
  ensure
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = saved
  end

  def test_mac_quit_hook_runs_the_window_close_handler
    main = GUI::MainWindow.new
    called = false
    main.root.protocol('WM_DELETE_WINDOW') { called = true }
    GUI.define_quit_hook
    Tk.tk_call(+'::tk::mac::Quit')
    assert called, 'Cmd-Q / app-menu Quit must reach the close handler (which saves and quits)'
  end

  def test_window_title_and_banner_say_where_things_are
    main = GUI::MainWindow.new
    assert_equal "RubyTalk: #{@dir}", main.send(:title)
    text = main.editor.contents
    assert_includes text, "Changes file: #{File.join(@dir, 'changes.rb')}"
    assert_includes text, "Working directory: #{Dir.pwd}"
    assert_includes text, "Running code from: #{RubyTalk::LIB_DIR}"
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
    assert_instance_of GUI::Debugger, GUI.windows.last
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
    assert_nil RubyTalk.changes.find_method('RtGuiThing', :instance, 'hi'), 'a method you created is forgotten, not logged'
    assert_equal %w[:hello :hi], RubyTalk.changes.versions('RtGuiThing', :instance, 'hi').map { |e| e.source[/:\w+/] },
                 'both the replaced and the removed source are kept as versions, newest first'
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
    assert_includes system_menu.entries.map { |_, options| options[:label] }, 'Change Directory...'
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
