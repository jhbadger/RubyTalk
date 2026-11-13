# frozen_string_literal: true

# Running code off the main thread: Stop, output and windows from a do it.
#   ruby test/test_gui_running.rb

require_relative 'support/gui_case'

class GuiRunningTest < GuiCase
  # --- running code off the main thread (interrupt) ------------------------


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
