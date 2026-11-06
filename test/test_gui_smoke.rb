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

  def test_tk_console_is_hidden_at_start_when_there_is_one
    Tk.console_present = true
    GUI.start
    assert_equal 'withdrawn', Tk.console_state, "Tk's Console window must not be left showing"
    assert_equal [GUI::MainWindow, GUI::Browser, GUI::Workspace], GUI.windows.last(3).map(&:class)
  ensure
    Tk.console_present = false
  end

  def test_no_console_is_fine
    Tk.console_present = false
    refute GUI.hide_tk_console, 'nothing to hide, and no error'
    GUI.start # must not raise
    Tk.console_present = true
    assert GUI.hide_tk_console
  ensure
    Tk.console_present = false
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

  # --- graphics windows (MVC hosted in Tk) -------------------------------------------

  def graphics_fixture
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    model = GraphicsExamples::Counter.new
    view = StandardSystemView.new('Counter test', model, Point.new(200, 80))
    view.add_subview(ButtonView.new('+', Rectangle.from(10, 10, 60, 30)) { model.increment })
    view.open(manager)
    [manager, model, view, GUI.windows.last]
  end

  def press(win, event, x, y)
    tk('event', 'generate', win.canvas.path, "<#{event}>", '-x', x.to_s, '-y', y.to_s)
  end

  def test_opening_a_view_makes_a_tk_window_with_its_picture
    refute_nil ControlManager.instance.opener, 'the Tk layer installs the opener'
    _manager, _model, view, win = graphics_fixture
    assert_instance_of GUI::GraphicsWindow, win
    assert_equal 'Counter test', Tk.last_title
    assert_instance_of TkCanvas, win.canvas
    assert_equal 200, win.canvas.options[:width]
    assert_equal 80, win.canvas.options[:height]
    assert_equal ['200', '80'], [tk('image', 'width', win.image), tk('image', 'height', win.image)].map(&:to_s),
                 'the window picture has been given to Tk, at the size of the view'
    assert_same view, win.view
  end

  def test_tk_mouse_events_reach_the_controllers_and_the_picture_updates
    _manager, model, view, win = graphics_fixture
    resting = Tk.photos[win.image]
    press(win, 'ButtonPress-1', 20, 20)
    refute_equal resting, Tk.photos[win.image], 'pressed: the button is drawn inverted and Tk was given the new picture'
    press(win, 'ButtonRelease-1', 20, 20)
    assert_equal 1, model.count, 'a click on the button, delivered as Tk events, ran its action'
    assert_equal resting, Tk.photos[win.image], 'released: back to the resting picture'

    press(win, 'Motion', 150, 60)
    press(win, 'ButtonPress-1', 20, 20)
    press(win, 'B1-Motion', 150, 60) # dragged off the button
    press(win, 'ButtonRelease-1', 150, 60)
    assert_equal 1, model.count, 'released outside: no action'
    assert_equal view.form.to_png, Tk.photos[win.image].unpack1('m'), 'Tk got exactly the window Form, as a PNG'
  end

  def test_tk_mouse_buttons_are_named_by_colour
    names = GUI::GraphicsWindow::BUTTON_NAMES
    assert_equal :red, names[1]
    assert_equal %i[blue yellow], [names[2], names[3]].sort
    assert_equal [1, 2, 3], names.keys
    pressed = []
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    view = StandardSystemView.new('Buttons', nil, Point.new(50, 50))
    view.controller = Class.new(Controller) { define_method(:mouse_down) { |_p, b| pressed << b } }.new(view)
    view.open(manager)
    win = GUI.windows.last
    [1, 2, 3].each { |n| press(win, "ButtonPress-#{n}", 5, 5) }
    assert_equal %i[red blue yellow].sort, pressed.sort
    assert_equal :red, pressed.first
  end

  def test_tk_key_and_leave_events_and_the_cursor
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    log = []
    view = StandardSystemView.new('Keys', nil, Point.new(60, 60))
    box = view.add_subview(View.new(nil, Rectangle.from(0, 0, 60, 60)))
    box.cursor = Cursor.crosshair
    box.controller = Class.new(Controller) do
      define_method(:key_pressed) { |char, keysym| log << [char, keysym] }
      define_method(:mouse_leave) { log << :leave }
    end.new(box)
    view.open(manager)
    win = GUI.windows.last
    press(win, 'Motion', 10, 10)
    tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'a')
    tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Left')
    assert_equal [['a', 'a'], ['', 'Left']], log, 'printable keys give their character, others only the keysym'
    assert_equal 'crosshair', manager.cursor_name(view), 'the cursor of the view under the pointer is applied'
    tk('event', 'generate', win.canvas.path, '<Leave>')
    assert_equal :leave, log.last
  end

  def scrolling_graphics_fixture(count = 30)
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    view = StandardSystemView.new('List test', nil, Point.new(120, 64))
    list = view.add_subview(ListView.new(Array.new(count) { |i| "item #{i}" }, Rectangle.from(0, 0, 120, 64)))
    view.open(manager)
    [manager, view, list, GUI.windows.last]
  end

  def test_tk_wheel_events_scroll_the_list_in_each_platforms_units
    _manager, _view, list, win = scrolling_graphics_fixture
    tk('event', 'generate', win.canvas.path, '<MouseWheel>', '-x', '20', '-y', '20', '-delta', '-1')
    assert_equal 1, list.top, 'Mac and X11 report small steps: a negative delta scrolls down a line'
    tk('event', 'generate', win.canvas.path, '<MouseWheel>', '-x', '20', '-y', '20', '-delta', '1')
    assert_equal 0, list.top, 'positive is up'
    tk('event', 'generate', win.canvas.path, '<MouseWheel>', '-x', '20', '-y', '20', '-delta', '-120')
    assert_equal 3, list.top, 'Windows reports multiples of 120: one notch is three lines'
    tk('event', 'generate', win.canvas.path, '<Button-5>', '-x', '20', '-y', '20')
    assert_equal 6, list.top, 'X11 wheel down is button 5'
    tk('event', 'generate', win.canvas.path, '<Button-4>', '-x', '20', '-y', '20')
    assert_equal 3, list.top
  end

  def test_tk_key_events_carry_the_modifier_state_and_command_keys_have_their_own_binding
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    seen = []
    view = StandardSystemView.new('Mods', nil, Point.new(60, 60))
    view.controller = Class.new(Controller) do
      define_method(:key_pressed) { |_char, keysym| seen << [:key, keysym, sensor.shift_pressed?] }
      define_method(:command_key) { |keysym| seen << [:command, keysym]; true }
      define_method(:mouse_down) { |_point, _button| seen << [:down, sensor.shift_pressed?] }
    end.new(view)
    view.open(manager)
    win = GUI.windows.last
    ControlManager.stub(:instance, manager) do
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Left', '-state', '0')
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Left', '-state', '1')
      tk('event', 'generate', win.canvas.path, "<#{GUI::MODIFIER}-Key>", '-keysym', 'c')
      tk('event', 'generate', win.canvas.path, '<ButtonPress-1>', '-x', '5', '-y', '5', '-state', '1')
    end
    assert_equal [[:key, 'Left', false], [:key, 'Left', true], [:command, 'c'], [:down, true]], seen
  end

  def test_a_yellow_button_menu_works_through_tk_events
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    chosen = []
    view = StandardSystemView.new('Menu test', nil, Point.new(160, 120))
    area = view.add_subview(View.new(nil, Rectangle.from(0, 0, 160, 120)))
    controller = MouseMenuController.new(area)
    controller.yellow_button_menu = PopUpMenu.new(%w[Alpha Beta]) { |_index, label| chosen << label }
    area.controller = controller
    view.open(manager)
    win = GUI.windows.last
    yellow = GUI::GraphicsWindow::BUTTON_NAMES.key(:yellow)
    resting = Tk.photos[win.image]
    press(win, "ButtonPress-#{yellow}", 50, 50)
    refute_nil view.popup, 'the press showed the menu'
    refute_equal resting, Tk.photos[win.image], 'and Tk was given the picture with the menu on it'
    press(win, 'B2-Motion', 50, 50 + 12 + 3)
    press(win, 'Motion', 50, 50 + 12 + 3)
    press(win, "ButtonRelease-#{yellow}", 50, 50 + 12 + 3)
    assert_equal ['Beta'], chosen
    assert_nil view.popup
    assert_equal resting, Tk.photos[win.image], 'the menu is gone from the picture'
  end

  def test_closing_the_tk_window_closes_the_view
    manager, model, view, win = graphics_fixture
    assert_equal [view], manager.windows
    win.window.protocols['WM_DELETE_WINDOW'].call
    assert_empty manager.windows
    assert_empty model.dependents
    assert win.window.destroyed?
    view.close(manager) # programmatic close of an already closed window: harmless
  end

  def test_closing_a_view_from_code_destroys_its_window
    manager, _model, view, win = graphics_fixture
    view.close(manager)
    assert win.window.destroyed?
  end

  def test_the_refresh_timer_redraws_views_changed_from_elsewhere
    manager = ControlManager.instance
    model = GraphicsExamples::Counter.new
    view = StandardSystemView.new('Timer test', model, Point.new(120, 40))
    view.add_subview(StringView.new(model, Rectangle.from(0, 0, 120, 20)) { |m| "n=#{m.count}" })
    view.open(manager)
    win = GUI.windows.last
    GUI.start_main_queue_timer
    first = Tk.photos[win.image]
    Thread.new { model.increment }.join # changed off the main thread: only flags the view
    assert_equal first, Tk.photos[win.image], 'nothing is drawn from the other thread'
    TkTimer.all.last.fire
    refute_equal first, Tk.photos[win.image], 'the timer, on the main thread, redraws it'
  ensure
    view&.close(manager)
  end

  def test_opening_a_view_from_a_do_it_goes_through_the_main_thread
    manager = ControlManager.instance
    with_pump do
      code = "v = StandardSystemView.new('From a do it', nil, Point.new(50, 40)); v.open; $rt_opened = v"
      GUI::Workspace.new(text: code).editor.do_it
      assert_instance_of GUI::GraphicsWindow, GUI.windows.last
      assert_equal 'From a do it', GUI.windows.last.view.label
      assert_equal ['50', '40'], [tk('image', 'width', GUI.windows.last.image), tk('image', 'height', GUI.windows.last.image)].map(&:to_s)
    end
  ensure
    $rt_opened&.close(manager)
    $rt_opened = nil
  end

  # --- file out and file in ---------------------------------------------------------

  def filed_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtGx\nend\n", changes: changes)
    Compiler.accept("def hello\n  :hello\nend\n", klass: RtGx, changes: changes)
    Compiler.accept("class RtGy\nend\n", changes: changes)
  end

  def drop_filed_fixture
    %i[RtGx RtGy RtFiled].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Tk.dialog_answer = nil
  end

  def test_file_out_class_writes_plain_ruby_to_the_chosen_file
    filed_fixture
    path = File.join(@dir, 'rt_gx.rb')
    Tk.dialog_answer = path
    GUI.file_out_class(RtGx)
    text = File.read(path)
    assert_includes text, 'def hello'
    refute_includes text, 'RtGy', 'only that class'
    assert_nil RubyTalk::Source.syntax_error(text)
    assert_match(/Filed out RtGx to #{Regexp.escape(path)}/, Transcript.buffer)
    request = Tk.dialog_requests.last
    assert_equal 'rt_gx.rb', request[request.index('-initialfile') + 1]
    assert_equal @dir, request[request.index('-initialdir') + 1], 'the dialog starts in the image folder'
  ensure
    drop_filed_fixture
  end

  def test_file_out_names_the_default_file_in_snake_case
    Compiler.accept("class RtFiled\nend\n", changes: RubyTalk.changes)
    Compiler.accept("class RtFiled::SomeThing\nend\n", changes: RubyTalk.changes)
    Tk.dialog_answer = ''
    GUI.file_out_class(RtFiled::SomeThing)
    request = Tk.dialog_requests.last
    assert_equal 'rt_filed_some_thing.rb', request[request.index('-initialfile') + 1]
  ensure
    drop_filed_fixture
  end

  def test_file_out_cancelled_nothing_to_file_out_and_unwritable
    filed_fixture
    Tk.dialog_answer = ''
    GUI.file_out_class(RtGx)
    GUI.file_out_changes
    refute Dir.glob(File.join(@dir, '*.rb')).any? { |file| File.basename(file) != 'changes.rb' }, 'Cancel writes nothing'

    GUI.file_out_class(Comparable)
    assert_match(/Nothing to file out: Comparable has no recorded changes/, Transcript.buffer)

    Tk.dialog_answer = '/nonexistent-dir-for-rubytalk/out.rb'
    GUI.file_out_class(RtGx) # must not raise
    assert_match(/Could not write/, Transcript.buffer)
  ensure
    drop_filed_fixture
  end

  def test_file_out_changes_writes_everything
    filed_fixture
    path = File.join(@dir, 'all.rb')
    Tk.dialog_answer = path
    GUI.file_out_changes
    text = File.read(path)
    assert_includes text, 'class RtGy'
    assert_includes text, 'def hello'
  ensure
    drop_filed_fixture
  end

  def test_file_in_reports_what_it_did
    path = File.join(@dir, 'in.rb')
    File.write(path, "class RtFiled\n  def a\n    1\n  end\n\n  def b\n    2\n  end\nend\n\nraise 'trouble'\n")
    Tk.dialog_answer = path
    summary = GUI.file_in
    assert_equal [1, 2, 1], [summary.classes, summary.methods, summary.errors.size]
    assert_equal 3, RtFiled.new.a + RtFiled.new.b
    assert_match(/Filed in in\.rb: 1 class created, 2 methods, 0 other class statements, 0 top-level statements run; 1 error/, Transcript.buffer)
    assert_match(/trouble/, Transcript.buffer)
    assert_equal 'in.rb', File.basename(path)
    request = Tk.dialog_requests.last
    assert_equal @dir, request[request.index('-initialdir') + 1]
  ensure
    drop_filed_fixture
  end

  def test_file_in_cancelled_and_unreadable
    Tk.dialog_answer = ''
    assert_nil GUI.file_in
    assert_nil GUI.file_in('/nonexistent-file-for-rubytalk.rb')
    assert_match(/Could not read/, Transcript.buffer)
  end

  def test_system_menu_and_class_menu_offer_file_out_and_in
    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    system_menu = menubar.entries.first[1][:menu]
    labels = system_menu.entries.map { |_, options| options[:label] }
    assert_includes labels, 'File In...'
    assert_includes labels, 'File Out Changes as Ruby...'

    path = File.join(@dir, 'menu.rb')
    File.write(path, "class RtFiled\n  def z\n    :z\n  end\nend\n")
    Tk.dialog_answer = path
    system_menu.invoke('File In...')
    assert_equal :z, RtFiled.new.z

    filed_fixture
    Tk.dialog_answer = File.join(@dir, 'from_browser.rb')
    GUI::Browser.open(RtGx).send(:file_out_class)
    assert File.file?(File.join(@dir, 'from_browser.rb'))
  ensure
    drop_filed_fixture
  end

  # --- remembered window layout ---------------------------------------------------

  def geometry_of(window)
    tk('wm', 'geometry', window.path).to_s
  end

  def set_geometry(window, spec)
    tk('wm', 'geometry', window.path, spec)
  end

  def test_windows_are_staggered_without_a_saved_layout
    first = GUI::Workspace.new(text: 'a').window
    second = GUI::Workspace.new(text: 'b').window
    refute_equal geometry_of(first), geometry_of(second)
  end

  def test_saved_layout_is_used_for_the_first_window_of_a_kind_and_nudged_for_the_next
    Preferences.save_layout(workspace: '500x400+100+120')
    first = GUI::Workspace.new(text: 'a').window
    second = GUI::Workspace.new(text: 'b').window
    assert_equal '500x400+100+120', geometry_of(first)
    assert_equal '500x400+128+148', geometry_of(second), 'a second window of the kind is nudged'
    browser = GUI::Browser.new
    assert_match(/\A100x100\+\d+\+\d+\z/, geometry_of(ivar(browser, :@window)), 'a kind with no saved layout is staggered')
  end

  def test_saved_geometry_is_kept_on_screen
    Tk.screen_width = 1000
    Tk.screen_height = 700
    Preferences.save_layout(workspace: '3000x2000+5000+900', browser: '400x300-900-50')
    assert_equal '960x620+900+640', geometry_of(GUI::Workspace.new(text: 'a').window), 'smaller than the screen, a corner showing'
    assert_equal '400x300-300+0', geometry_of(ivar(GUI::Browser.new, :@window)), 'no more than all but 100 pixels off the left'
  end

  def test_layout_is_saved_on_quit_one_entry_per_kind_from_the_newest_window
    first = GUI::Workspace.new(text: 'a').window
    set_geometry(first, '300x200+10+10')
    second = GUI::Workspace.new(text: 'b').window
    set_geometry(second, '640x480+50+60')
    GUI::MainWindow.new
    GUI.quit
    layout = Preferences.layout
    assert_equal '640x480+50+60', layout['workspace']
    assert layout.key?('transcript')
  end

  def test_closing_a_window_remembers_where_it_was
    window = GUI::Workspace.new(text: 'a').window
    set_geometry(window, '321x234+11+22')
    window.protocols['WM_DELETE_WINDOW'].call
    assert window.destroyed?
    GUI.save_layout
    assert_equal '321x234+11+22', Preferences.layout['workspace'], 'kept although no window of that kind is open now'
  end

  def test_the_transcript_keeps_its_quit_handler
    main = GUI::MainWindow.new
    quit_called = false
    GUI.stub(:quit, -> { quit_called = true }) { main.root.protocols['WM_DELETE_WINDOW'].call }
    assert quit_called, 'closing the Transcript quits; it is not just another window'
  end

  def test_change_directory_saves_the_layout_first
    set_geometry(GUI::Workspace.new(text: 'a').window, '700x500+30+40')
    change_directory_with(File.join(@dir, 'elsewhere'))
    assert_equal '700x500+30+40', Preferences.layout['workspace']
  end

  def test_a_failing_layout_save_does_not_stop_quitting
    ENV['HOME'] = '/nonexistent-home-for-rubytalk'
    GUI::Workspace.new(text: 'a')
    GUI.quit # must not raise
    assert Tk.root.destroyed?
  end

  # --- auto-indent and bracket matching -----------------------------------------

  # A code pane with the cursor at +offset+ (default: the very end).
  def code_pane(text, offset = nil)
    editor = GUI::Workspace.new(text: text).editor
    editor.text.insert_offset = offset || text.size
    editor
  end

  def test_return_keeps_and_adds_indentation
    {
      'def foo' => "def foo\n  ",
      '  if x' => "  if x\n    ",
      '  a = 1' => "  a = 1\n  ",
      'items.each do |x|' => "items.each do |x|\n  ",
      '  end' => "  end\n  "
    }.each do |text, expected|
      editor = code_pane(text)
      assert_equal :break, editor.text.fire('Return'), 'the default newline is suppressed'
      assert_equal expected, editor.contents, text.inspect
      assert_equal expected.size, editor.text.insert_offset, 'the cursor is on the new line, after the indentation'
    end
  end

  def test_return_in_the_middle_of_a_line_and_over_a_selection
    editor = code_pane('foo(a)', 4)
    editor.text.fire('Return')
    assert_equal "foo(\n  a)", editor.contents

    editor = code_pane('abc def', 3)
    editor.text.select_text('abc')
    editor.text.fire('Return')
    assert_equal "\n def", editor.contents, 'a selection is replaced, as Return normally does'
  end

  def test_tab_inserts_two_spaces
    editor = code_pane('x')
    assert_equal :break, editor.text.fire('Tab')
    assert_equal 'x  ', editor.contents
  end

  def test_typing_end_else_or_a_closer_lines_up_with_its_opener
    editor = code_pane("def foo\n  if x\n    a\n    end")
    editor.text.fire('KeyRelease')
    assert_equal "def foo\n  if x\n    a\n  end", editor.contents
    assert_equal editor.contents.size, editor.text.insert_offset, 'the cursor stays at the end of the line'

    editor = code_pane("def foo\n  if x\n    a\n    else")
    editor.text.fire('KeyRelease')
    assert_equal "def foo\n  if x\n    a\n  else", editor.contents

    editor = code_pane("h = {\n  a: 1\n  }")
    editor.text.fire('KeyRelease')
    assert_equal "h = {\n  a: 1\n}", editor.contents
  end

  def test_dedent_leaves_existing_code_and_other_lines_alone
    [
      ["def foo\n  a\n      end", nil],            # indented by hand: not the auto-indent position
      ["def foo\n  a\n  endless = 1", nil],        # not a closer
      ["def foo\n  a\n  when: 1", nil]
    ].each do |text, _|
      editor = code_pane(text)
      editor.text.fire('KeyRelease')
      assert_equal text, editor.contents, text.inspect
    end
    editor = code_pane("def foo\n  if x\n    a\n    end\nmore", 30) # cursor not at the end of that line
    before = editor.contents
    editor.text.fire('KeyRelease')
    assert_equal before, editor.contents
  end

  def test_the_bracket_next_to_the_cursor_is_marked_with_its_partner
    editor = code_pane('foo(a, [1])', 11)
    editor.text.fire('KeyRelease')
    names = ->(index) { editor.text.tag_command(['names', index]).split }
    assert_includes names.call('1.3'), 'rt_bracket'
    assert_includes names.call('1.10'), 'rt_bracket'
    refute_includes names.call('1.4'), 'rt_bracket'

    editor.text.insert_offset = 5 # not next to a bracket
    editor.text.fire('KeyRelease')
    assert_nil editor.text.tag_store.fetch('rt_bracket', nil), 'the marks go when the cursor moves away'

    editor.text.insert_offset = 4 # just after the opener, by clicking
    editor.text.fire('ButtonRelease-1')
    assert_includes names.call('1.10'), 'rt_bracket'

    unbalanced = code_pane('foo(a', 4)
    unbalanced.text.fire('KeyRelease')
    assert_nil unbalanced.text.tag_store.fetch('rt_bracket', nil), 'no partner, nothing to mark'
  end

  def test_the_transcript_and_find_entries_have_no_smart_editing
    main = GUI::MainWindow.new
    refute main.editor.text.bindings.key?('Return'), 'Return in the Transcript is untouched'
    refute main.editor.text.bindings.key?('Tab')
    main.editor.show_find
    refute main.editor.find_bar.find_entry.bindings.key?('Tab')
  end

  # --- find and replace ------------------------------------------------------

  def find_fixture(text)
    editor = GUI::Workspace.new(text: text).editor
    editor.show_find
    [editor, editor.find_bar]
  end

  def type_find(bar, pattern)
    bar.find_var.value = +pattern
    bar.find_entry.fire('KeyRelease')
  end

  # Tk calls with unfrozen strings (this file's literals are frozen, and the tk gem mutates its arguments).
  def tk(*args)
    Tk.tk_call(*args.map { |arg| arg.is_a?(String) ? arg.dup : arg })
  end

  def selection_start(editor)
    tk(editor.text.path, 'count', '-chars', '1.0', 'sel.first').to_i
  end

  def marks(editor)
    editor.text.tag_store.fetch('rt_find', nil)
  end

  def find_status(bar)
    ivar(bar, :@status).options[:text]
  end

  def test_find_marks_every_match_and_selects_the_first
    editor, bar = find_fixture('alpha beta alpha')
    assert bar.visible?
    type_find(bar, 'alpha')
    assert_equal [[0, 5], [11, 16]], marks(editor)
    assert_equal 'alpha', editor.text.get('sel.first', 'sel.last')
    assert_equal 0, selection_start(editor)
    assert_equal '2 matches', find_status(bar)
    type_find(bar, 'beta')
    assert_equal [[6, 10]], marks(editor), 'the old marks are replaced'
    assert_equal 6, selection_start(editor)
    type_find(bar, 'nothing')
    assert_nil marks(editor)
    assert_equal 'No match', find_status(bar)
  end

  def test_find_next_and_previous_step_and_wrap
    editor, bar = find_fixture('a b a b a')
    type_find(bar, 'a')
    assert_equal 0, selection_start(editor)
    bar.find(forward: true)
    assert_equal 4, selection_start(editor)
    bar.find(forward: true)
    assert_equal 8, selection_start(editor)
    bar.find(forward: true)
    assert_equal 0, selection_start(editor)
    assert_match(/wrapped/, find_status(bar))
    bar.find(forward: false)
    assert_equal 8, selection_start(editor), 'backwards from the first wraps to the last'
    bar.find(forward: false)
    assert_equal 4, selection_start(editor)
  end

  def test_find_match_case_and_regexp_options
    editor, bar = find_fixture('Alpha alpha a1 a22')
    type_find(bar, 'alpha')
    assert_equal 2, marks(editor).size
    ivar(bar, :@case_var).value = +'1'
    bar.send(:refresh)
    assert_equal 1, marks(editor).size, 'match case'
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, 'a\d+')
    assert_equal 2, marks(editor).size, 'regexp'
    type_find(bar, '(')
    assert_match(/Invalid pattern/, find_status(bar))
    assert_nil marks(editor)
  end

  def test_find_prefills_from_the_selection
    editor = GUI::Workspace.new(text: 'one two three').editor
    editor.text.select_text('two')
    editor.show_find
    assert_equal 'two', editor.find_bar.find_var.value
    assert_equal [[4, 7]], marks(editor)
  end

  def test_replace_steps_through_matches
    editor, bar = find_fixture('foo bar foo')
    type_find(bar, 'foo')
    bar.replace_var.value = +'baz'
    bar.replace
    assert_equal 'baz bar foo', editor.contents
    assert_equal 8, selection_start(editor), 'moves on to the next match'
    bar.replace
    assert_equal 'baz bar baz', editor.contents
    bar.replace
    assert_equal 'baz bar baz', editor.contents, 'nothing left to replace'
    assert_equal 'No match', find_status(bar)
  end

  def test_replace_with_no_match_selected_first_finds_one
    editor, bar = find_fixture('foo bar foo')
    type_find(bar, 'foo')
    editor.text.tag_remove('sel', '1.0', 'end')
    tk(editor.text.path, 'mark', 'set', 'insert', '1.5')
    bar.replace_var.value = +'X'
    bar.replace
    assert_equal 'foo bar foo', editor.contents, 'the first press only selects the next match'
    assert_equal 8, selection_start(editor)
    bar.replace
    assert_equal 'foo bar X', editor.contents
  end

  def test_replace_all
    editor, bar = find_fixture('a1 b22 c333')
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, '\d+')
    bar.replace_var.value = +'#'
    bar.replace_all
    assert_equal 'a# b# c#', editor.contents
    assert_equal 'Replaced 3', find_status(bar)
  end

  def test_replace_all_with_groups_and_multibyte_text
    editor, bar = find_fixture('John Smith é é')
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, '(\w+) (\w+)')
    bar.replace_var.value = +'\2 \1'
    bar.replace_all
    assert_equal 'Smith John é é', editor.contents
    ivar(bar, :@regexp_var).value = +'0'
    type_find(bar, 'é')
    bar.replace_var.value = +'e'
    bar.replace_all
    assert_equal 'Smith John e e', editor.contents
  end

  def test_find_key_bindings_menu_and_escape
    editor = GUI::Workspace.new(text: 'x y x').editor
    assert_equal :break, editor.text.fire("#{GUI::MODIFIER}-Key-f")
    bar = editor.find_bar
    assert bar.visible?
    type_find(bar, 'x')
    editor.text.fire("#{GUI::MODIFIER}-Key-g")
    assert_equal 4, selection_start(editor)
    editor.text.fire("#{GUI::MODIFIER}-Key-G")
    assert_equal 0, selection_start(editor)
    bar.find_entry.fire('Escape')
    refute bar.visible?
    assert_nil marks(editor), 'the marks go when the bar closes'
    editor.text.fire("#{GUI::MODIFIER}-Key-g") # Cmd-G with the bar closed opens it
    assert bar.visible?

    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    labels = menubar.entries.last[1][:menu].entries.map { |_, options| options[:label] }
    assert_includes labels, 'Find...'
    assert_includes labels, 'Find Next'
    assert_includes labels, 'Find Previous'
  end

  def test_find_follows_changes_to_the_text
    editor, bar = find_fixture('x')
    type_find(bar, 'x')
    editor.set_contents('x x x')
    assert_equal 3, marks(editor).size, 'new contents are searched'
    editor.text.insert('end', +' x')
    editor.text.fire('KeyRelease')
    assert_equal 4, marks(editor).size, 'typing updates the marks'
  end

  def test_the_transcript_can_be_searched_too
    main = GUI::MainWindow.new
    Transcript.show_cr('searchable line')
    main.editor.show_find
    type_find(main.editor.find_bar, 'searchable')
    assert_equal 1, marks(main.editor).size
  end

  # --- test runner -------------------------------------------------------

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

  # --- class comments ----------------------------------------------------

  def test_browser_shows_and_edits_class_comments
    Object.const_set(:RtCommented, Class.new)
    browser = GUI::Browser.open(RtCommented)
    assert_equal "class RtCommented < Object\nend\n", browser.code.contents, 'no comment yet'
    browser.code.set_contents("# Says hello.\nclass RtCommented < Object\nend\n")
    browser.code.accept
    assert_equal "# Says hello.\nclass RtCommented < Object\nend\n", browser.code.contents
    again = GUI::Browser.open(RtCommented)
    assert_equal "# Says hello.\nclass RtCommented < Object\nend\n", again.code.contents, 'a new browser shows it too'
    tags = again.code.text.tag_command(['names', '1.2']).split
    assert_includes tags, 'rt_comment'
  ensure
    Object.send(:remove_const, :RtCommented) if defined?(RtCommented)
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
