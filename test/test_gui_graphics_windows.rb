# frozen_string_literal: true

# MVC windows hosted in Tk.
#   ruby test/test_gui_graphics_windows.rb

require_relative 'support/gui_case'

class GuiGraphicsWindowsTest < GuiCase
  def graphics_fixture
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    model = GraphicsExamples::Counter.new
    view = StandardSystemView.new('Counter test', model, Point.new(200, 80))
    view.add_subview(ButtonView.new('+', Rectangle.from(10, 10, 60, 30)) { model.increment })
    view.open(manager)
    [manager, model, view, GUI.windows.last]
  end

  def scrolling_graphics_fixture(count = 30)
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    view = StandardSystemView.new('List test', nil, Point.new(120, 64))
    list = view.add_subview(ListView.new(Array.new(count) { |i| "item #{i}" }, Rectangle.from(0, 0, 120, 64)))
    view.open(manager)
    [manager, view, list, GUI.windows.last]
  end

  # --- graphics windows (MVC hosted in Tk) -------------------------------------------



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

  def test_the_clipboard_is_the_tk_clipboard
    assert_equal GUI::TkClipboard, Clipboard.backend
    Tk.clipboard_text = nil
    assert_equal '', Clipboard.text, 'an empty Tk clipboard reads as an empty string, not an error'
    Clipboard.text = '-starts with a dash'
    assert_equal '-starts with a dash', Tk.clipboard_text
    assert_equal '-starts with a dash', Clipboard.text
    Clipboard.text = 'second'
    assert_equal 'second', Tk.clipboard_text, 'setting clears first'
  ensure
    Tk.clipboard_text = nil
  end

  def test_typing_and_command_keys_edit_a_text_view_through_tk_events
    manager = ControlManager.new
    manager.opener = ->(view) { GUI::GraphicsWindow.new(view, manager) }
    view = StandardSystemView.new('Editor test', nil, Point.new(200, 60))
    field = view.add_subview(TextView.new(nil, Rectangle.from(0, 0, 200, 60)))
    view.open(manager)
    win = GUI.windows.last
    ControlManager.stub(:instance, manager) do
      resting = Tk.photos[win.image]
      press(win, 'ButtonPress-1', 20, 20)
      press(win, 'ButtonRelease-1', 20, 20)
      %w[h i].each { |letter| tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', letter) }
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Return')
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'x')
      assert_equal "hi\nx", field.text
      refute_equal resting, Tk.photos[win.image], 'the typing reached the picture Tk shows'
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'BackSpace')
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Left', '-state', '1') # shift-left selects
      assert_equal "hi\n", field.text
      assert_equal [2, 3], field.selection_range

      tk('event', 'generate', win.canvas.path, "<#{GUI::MODIFIER}-Key>", '-keysym', 'a')
      tk('event', 'generate', win.canvas.path, "<#{GUI::MODIFIER}-Key>", '-keysym', 'c')
      assert_equal "hi\n", Tk.clipboard_text, 'copied to the system clipboard'
      tk('event', 'generate', win.canvas.path, '<KeyPress>', '-keysym', 'Delete')
      assert_equal '', field.text
      tk('event', 'generate', win.canvas.path, "<#{GUI::MODIFIER}-Key>", '-keysym', 'v')
      assert_equal "hi\n", field.text, 'pasted back from it'
    end
  ensure
    Tk.clipboard_text = nil
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
end
