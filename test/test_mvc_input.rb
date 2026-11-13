# frozen_string_literal: true

# Keyboard focus, modifiers, clicks, and the example programs.
#   ruby test/test_mvc_input.rb

require_relative 'support/mvc_case'

class MvcInputTest < MvcCase
  # --- Keyboard focus, modifiers and clicks --------------------------------------------------

  def test_focus_follows_clicks_on_controllers_that_want_it
    top = window(pt(100, 100))
    lists = [ListView.new(%w[a b], Rectangle.from(0, 0, 50, 100)), ListView.new(%w[c d], Rectangle.from(50, 0, 50, 100))]
    lists.each { |list| top.add_subview(list) }
    button = top.add_subview(ButtonView.new('x', Rectangle.from(0, 80, 20, 20)))
    top.open(@manager)
    assert_nil @manager.focus_controller(top)
    @manager.mouse_down(top, 10, 5, :red)
    @manager.mouse_up(top, 10, 5, :red)
    assert_same lists[0].controller, @manager.focus_controller(top)
    @manager.mouse_down(top, 60, 5, :red)
    @manager.mouse_up(top, 60, 5, :red)
    assert_same lists[1].controller, @manager.focus_controller(top)
    @manager.mouse_down(top, 5, 85, :red) # a button does not want the keyboard: focus stays
    @manager.mouse_up(top, 5, 85, :red)
    assert_same lists[1].controller, @manager.focus_controller(top)
    refute button.controller.wants_keyboard_focus?
    @manager.mouse_move(top, 10, 50)
    @manager.key(top, '', 'Down') # goes to the focused list, not the one under the pointer
    assert_equal 1, lists[1].selection, 'the click selected row 0, so Down moves to row 1'
    assert_equal 0, lists[0].selection, 'the other list kept its own selection (from the earlier click)'
    top.close(@manager)
    assert_nil @manager.focus_controller(top)
  end

  def test_focus_gained_and_lost_are_announced
    log = []
    top = window(pt(100, 50))
    listener = lambda do |name|
      Class.new(ListController) do
        define_method(:focus_gained) { log << [name, :gained] }
        define_method(:focus_lost) { log << [name, :lost] }
      end
    end
    a = top.add_subview(ListView.new(%w[a], Rectangle.from(0, 0, 50, 50)))
    b = top.add_subview(ListView.new(%w[b], Rectangle.from(50, 0, 50, 50)))
    a.controller = listener.call(:a).new(a)
    b.controller = listener.call(:b).new(b)
    top.open(@manager)
    @manager.mouse_down(top, 10, 5, :red)
    @manager.mouse_up(top, 10, 5, :red)
    @manager.mouse_down(top, 10, 5, :red) # same one again: no new announcement
    @manager.mouse_up(top, 10, 5, :red)
    @manager.mouse_down(top, 60, 5, :red)
    assert_equal [[:a, :gained], [:a, :lost], [:b, :gained]], log
  end

  def test_modifier_keys_reach_the_sensor
    seen = []
    controller = Class.new(Controller) do
      define_method(:key_pressed) { |_char, keysym| seen << [keysym, sensor.shift_pressed?, sensor.control_pressed?] }
    end
    top = window
    top.controller = controller.new(top)
    top.open(@manager)
    ControlManager.stub(:instance, @manager) do
      @manager.key(top, '', 'Left', 0)
      @manager.key(top, '', 'Left', InputSensor::SHIFT)
      @manager.key(top, '', 'Left', InputSensor::SHIFT | InputSensor::CONTROL)
    end
    assert_equal [['Left', false, false], ['Left', true, false], ['Left', true, true]], seen
    @manager.mouse_down(top, 1, 1, :red, InputSensor::SHIFT)
    assert @manager.sensor.shift_pressed?, 'mouse events carry the modifiers too'
  end

  def test_double_and_triple_clicks_are_counted
    now = 100.0
    @manager.clock = -> { now }
    top = window
    top.open(@manager)
    counts = lambda do |x, y, button = :red|
      @manager.mouse_down(top, x, y, button)
      @manager.mouse_up(top, x, y, button)
      @manager.sensor.click_count
    end
    assert_equal 1, counts.call(10, 10)
    now += 0.2
    assert_equal 2, counts.call(11, 10), 'quickly, nearly the same place'
    now += 0.2
    assert_equal 3, counts.call(10, 11)
    now += 0.2
    assert_equal 3, counts.call(10, 10), 'it stops at 3'
    now += 0.2
    assert_equal 3, counts.call(10, 10)
    now += 1.0
    assert_equal 1, counts.call(10, 10), 'too slow'
    now += 0.1
    assert_equal 1, counts.call(60, 10), 'too far'
    now += 0.1
    assert_equal 1, counts.call(60, 10, :yellow), 'a different button'
  end

  def test_command_keys_go_to_the_focused_controller_and_report_whether_they_were_used
    handled = []
    controller = Class.new(Controller) do
      define_method(:command_key) { |keysym| handled << keysym; keysym == 'c' }
      define_method(:wants_keyboard_focus?) { true }
    end
    top = window
    top.controller = controller.new(top)
    top.open(@manager)
    assert_equal true, @manager.command_key(top, 'c')
    assert_equal false, @manager.command_key(top, 'q')
    assert_equal %w[c q], handled
    assert_equal false, window.controller.command_key('c'), 'the default is "not handled"'
  end

  # --- The example programs ---------------------------------------------------------------

  def test_counter_example_counts_through_its_buttons
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      window = GraphicsExamples::Counter.open
      model = window.subviews.first.model
      click = ->(x, y) { manager.mouse_down(window, x, y, :red); manager.mouse_up(window, x, y, :red) }
      click.call(200, 70)
      click.call(200, 70)
      click.call(200, 70)
      click.call(30, 70)
      assert_equal 2, model.count
      click.call(120, 70)
      assert_equal 0, model.count
      refute_nil window.form
      assert_operator window.form.copy(Rectangle.from(10, 10, 220, 24)).to_ascii.join.count('#'), :>, 10
      before = window.form.dup
      click.call(200, 70)
      refute_equal before, window.form, 'the picture changed with the model'
    end
  end

  def test_sketch_example_draws_erases_clears_and_takes_keys
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      window = GraphicsExamples::Sketch.open(100, 80)
      model = window.subviews.first.model
      manager.mouse_down(window, 10, 10, :red)
      manager.mouse_move(window, 40, 10)
      manager.mouse_up(window, 40, 10, :red)
      assert_equal 0, model.form[25, 10], 'drawn in black while dragging'
      assert_equal 0, window.form[25, 10], 'and visible in the window'
      manager.mouse_move(window, 60, 60) # no button: no drawing
      assert_equal 0xFFFFFF, model.form[60, 60]

      manager.mouse_move(window, 10, 10)
      manager.key(window, 'r')
      manager.key(window, '5')
      assert_equal [Color.red, 5], [model.color, model.width]
      manager.mouse_down(window, 10, 40, :red)
      manager.mouse_up(window, 10, 40, :red)
      assert_equal 0xFF0000, model.form[10, 40]

      manager.mouse_move(window, 25, 10)
      manager.mouse_down(window, 25, 10, :yellow) # erase
      manager.mouse_up(window, 25, 10, :yellow)
      assert_equal 0xFFFFFF, model.form[25, 10]

      manager.key(window, 'c')
      assert_equal 0, model.form.to_ascii(ink_color: Color.red).join.count('#')
      manager.mouse_down(window, 10, 10, :red)
      manager.mouse_up(window, 10, 10, :red)
      manager.mouse_down(window, 10, 10, :blue) # blue clears
      manager.mouse_up(window, 10, 10, :blue)
      assert_equal 0xFFFFFF, model.form[10, 10]
      manager.key(window, 'k')
      assert_equal Color.black, model.color
      manager.key(window, 'z') # ignored
      manager.key(window, '0') # not a width
      assert_equal 5, model.width
    end
  end
end
