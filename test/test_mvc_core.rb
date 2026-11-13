# frozen_string_literal: true

# Model-View-Controller: models, views, controllers and windows.
#   ruby test/test_mvc_core.rb

require_relative 'support/mvc_case'

class MvcCoreTest < MvcCase
  # --- Model and dependency --------------------------------------------------

  def test_model_changes_invalidate_the_views_that_depend_on_it
    model = Model.new
    view = window(pt(40, 40), model)
    @manager.open(view)
    refute view.invalidated, 'drawn at open'
    model.changed(:anything)
    assert view.invalidated, 'the dependent view asked for a redraw'
    @manager.refresh(view)
    refute view.invalidated
    assert_equal [view], model.dependents
  end

  def test_changing_the_model_of_a_view_moves_the_dependency
    first = Model.new
    second = Model.new
    view = View.new(first)
    view.model = second
    assert_empty first.dependents
    assert_equal [view], second.dependents
    view.model = nil
    assert_empty second.dependents
    plain = View.new(Object.new) # a model that has no dependents: fine
    assert_kind_of Object, plain.model
  end

  def test_views_can_select_what_they_react_to
    model = Model.new
    picky = Class.new(View) do
      def update(aspect, _with)
        invalidate if aspect == :wanted
      end
    end.new(model)
    top = window
    top.add_subview(picky)
    top.invalidated = false
    model.changed(:other)
    refute top.invalidated
    model.changed(:wanted)
    assert top.invalidated
  end

  # --- Views: structure and drawing ----------------------------------------------

  def test_subviews_are_drawn_at_their_bounds_in_their_own_coordinates
    top = window(pt(100, 80))
    top.background = Color.white
    red = SolidView.new(Color.red, Rectangle.from(10, 20, 30, 10))
    top.add_subview(red)
    form = top.render
    assert_equal [100, 80], [form.width, form.height]
    assert_equal 0xFF0000, form[10, 20]
    assert_equal 0xFF0000, form[39, 29]
    assert_equal 0xFFFFFF, form[40, 29], 'just outside'
    assert_equal 0xFFFFFF, form[9, 20]
    assert_equal 0xFFFFFF, form[10, 30]
  end

  def test_a_view_cannot_draw_outside_its_bounds
    top = window(pt(60, 60))
    greedy = Class.new(View) do
      def display_view(form)
        form.fill(Rectangle.from(-50, -50, 500, 500), Color.blue) # far bigger than the view
      end
    end.new(nil, Rectangle.from(20, 20, 20, 20))
    top.add_subview(greedy)
    form = top.render
    assert_equal 0x0000FF, form[20, 20]
    assert_equal 0x0000FF, form[39, 39]
    assert_equal 0xFFFFFF, form[19, 20]
    assert_equal 0xFFFFFF, form[40, 40]
  end

  def test_nested_views_stack_in_order_and_later_ones_are_on_top
    top = window(pt(100, 100))
    outer = top.add_subview(SolidView.new(Color.green, Rectangle.from(10, 10, 60, 60)))
    inner = outer.add_subview(SolidView.new(Color.blue, Rectangle.from(10, 10, 20, 20)))
    over = top.add_subview(SolidView.new(Color.red, Rectangle.from(15, 15, 10, 10)))
    form = top.render
    assert_equal 0x00A000, form[11, 11], 'the outer view'
    assert_equal 0x0000FF, form[30, 30], 'inside it: the outer view is at 10,10 and the inner at 10,10 within it'
    assert_equal 0xFF0000, form[16, 16], 'a later sibling covers earlier ones'
    assert_equal [outer, over], top.subviews
    assert_equal top, inner.top_view
    assert_equal pt(20, 20), inner.origin_in_top
    assert_equal pt(5, 5), inner.to_local(pt(25, 25))
  end

  def test_borders_backgrounds_and_colours
    view = View.new(nil, Rectangle.from(0, 0, 10, 10))
    view.background = Color.yellow
    view.foreground = Color.red
    view.border_width = 1
    form = view.render
    assert_equal 0xFF0000, form[0, 0]
    assert_equal 0xFF0000, form[9, 5]
    assert_equal 0xFFFF00, form[5, 5]
    assert_equal 'a View(0@0 corner: 10@10)', view.to_s
  end

  def test_view_at_finds_the_deepest_view_and_the_local_point
    top = window(pt(100, 100))
    a = top.add_subview(SolidView.new(Color.red, Rectangle.from(10, 10, 50, 50)))
    b = a.add_subview(SolidView.new(Color.blue, Rectangle.from(5, 5, 20, 20)))
    c = top.add_subview(SolidView.new(Color.green, Rectangle.from(40, 40, 30, 30)))
    assert_equal [top, pt(1, 1)], top.view_at(pt(1, 1))
    assert_equal [a, pt(2, 40)], top.view_at(pt(12, 50))
    assert_equal [b, pt(0, 0)], top.view_at(pt(15, 15)), 'a subview of a subview'
    assert_equal [c, pt(0, 0)], top.view_at(pt(40, 40)), 'where two overlap the later one wins'
    assert_equal [c, pt(29, 29)], top.view_at(pt(69, 69))
    assert_equal [top, pt(99, 99)], top.view_at(pt(99, 99))
    top.remove_subview(c)
    assert_equal [a, pt(30, 30)], top.view_at(pt(40, 40))
    assert_nil c.superview
  end

  def test_release_stops_depending_on_the_model
    model = Model.new
    top = window(pt(50, 50), model)
    inner = top.add_subview(View.new(model, Rectangle.from(0, 0, 10, 10)))
    assert_equal 2, model.dependents.size
    top.release
    assert_empty model.dependents
    assert_same top, inner.superview, 'release only stops the dependencies; the tree is left as it was'
  end

  # --- Controllers and the manager ---------------------------------------------------

  def test_controller_events_arrive_in_the_views_own_coordinates
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(20, 30, 40, 40)))
    recorder = with_recorder(box)
    @manager.open(top)
    @manager.mouse_move(top, 25, 35)
    @manager.mouse_down(top, 25, 35, :red)
    @manager.mouse_up(top, 25, 35, :red)
    assert_equal [:enter, :initialize, [:move, pt(5, 5)], :activity,
                  [:down, pt(5, 5), :red], :activity,
                  [:up, pt(5, 5), :red], :activity], recorder.log
  end

  def test_enter_and_leave_follow_the_pointer_between_views
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    right = with_recorder(top.add_subview(View.new(nil, Rectangle.from(50, 0, 50, 100))))
    @manager.open(top)
    @manager.mouse_move(top, 10, 10)
    @manager.mouse_move(top, 20, 10)
    @manager.mouse_move(top, 60, 10)
    @manager.mouse_move(top, 70, 10)
    @manager.mouse_leave(top)
    assert_equal [:enter, :initialize, [:move, pt(10, 10)], :activity, [:move, pt(20, 10)], :activity,
                  :leave, :terminate], left.log
    assert_equal [:enter, :initialize, [:move, pt(10, 10)], :activity, [:move, pt(20, 10)], :activity,
                  :leave, :terminate], right.log, 'leaving the window counts as leaving the view'
  end

  def test_the_view_that_got_the_button_down_keeps_the_mouse_until_it_is_up
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    right = with_recorder(top.add_subview(View.new(nil, Rectangle.from(50, 0, 50, 100))))
    @manager.open(top)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_move(top, 80, 20) # dragged over the other view
    @manager.mouse_up(top, 90, 30, :red)
    downs = left.log.select { |e| e.is_a?(Array) }
    assert_equal [[:down, pt(10, 10), :red], [:move, pt(80, 20)], [:up, pt(90, 30), :red]], downs,
                 'the dragged-from view gets the moves and the release, in its own coordinates, even outside it'
    assert_empty right.log.select { |e| e.is_a?(Array) }, 'the view dragged over gets none of them'
    @manager.mouse_move(top, 60, 60) # the capture is over
    assert_equal [[:move, pt(10, 60)]], right.log.select { |e| e.is_a?(Array) }
  end

  def test_sensor_tracks_the_mouse_and_buttons
    top = window
    @manager.open(top)
    sensor = @manager.sensor
    refute sensor.any_button_pressed?
    @manager.mouse_down(top, 12, 34, :red)
    assert sensor.red_button_pressed?
    refute sensor.yellow_button_pressed?
    assert_equal pt(12, 34), sensor.cursor_point
    @manager.mouse_down(top, 12, 34, :blue)
    assert sensor.blue_button_pressed?
    @manager.mouse_up(top, 12, 34, :red)
    refute sensor.red_button_pressed?
    assert sensor.any_button_pressed?
    @manager.mouse_up(top, 12, 34, :blue)
    refute sensor.any_button_pressed?
    @manager.key(top, 'q')
    assert_equal 'q', sensor.last_key
    assert_raises(ArgumentError) { sensor.press(:green) }
  end

  def test_sensor_is_available_to_controllers_for_polling_style_code
    seen = []
    controller = Class.new(Controller) do
      define_method(:mouse_move) { |_point| seen << sensor.red_button_pressed? }
    end
    top = window
    top.controller = controller.new
    top.controller.view = top
    @manager.open(top)
    ControlManager.stub(:instance, @manager) do
      @manager.mouse_move(top, 5, 5)
      @manager.mouse_down(top, 5, 5, :red)
      @manager.mouse_move(top, 6, 6)
    end
    assert_equal [false, true], seen
  end

  def test_keys_go_to_the_controller_under_the_pointer
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    top_recorder = with_recorder(top)
    @manager.open(top)
    @manager.key(top, 'a', 'a') # pointer not over anything yet: the window's controller
    @manager.mouse_move(top, 10, 10)
    @manager.key(top, 'b', 'b')
    @manager.key(top, '', 'Left')
    assert_equal [[:key, 'a', 'a']], top_recorder.log.select { |e| e.is_a?(Array) && e.first == :key }
    assert_equal [[:key, 'b', 'b'], [:key, '', 'Left']], left.log.select { |e| e.is_a?(Array) && e.first == :key }
  end

  def test_control_wanted_means_the_pointer_is_in_the_view
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(20, 20, 30, 30)))
    controller = with_recorder(box)
    @manager.open(top)
    ControlManager.stub(:instance, @manager) do
      @manager.mouse_move(top, 25, 25)
      assert controller.control_wanted?
      @manager.mouse_move(top, 80, 80)
      refute controller.control_wanted?
    end
  end

  def test_errors_in_a_controller_are_reported_not_raised
    top = window
    boom = Class.new(Controller) do
      def mouse_down(_point, _button)
        raise 'controller trouble'
      end
    end
    top.controller = boom.new
    top.controller.view = top
    @manager.open(top)
    @manager.mouse_down(top, 5, 5, :red) # must not raise
    assert_match(/Error in the window 'Test'.*controller trouble/m, Transcript.buffer)
    @manager.mouse_up(top, 5, 5, :red)
    @manager.mouse_move(top, 6, 6) # and the window still works
  end

  def test_cursor_names
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100)))
    box.cursor = Cursor.crosshair
    @manager.open(top)
    assert_equal 'arrow', @manager.cursor_name(top)
    @manager.mouse_move(top, 10, 10)
    assert_equal 'crosshair', @manager.cursor_name(top)
    @manager.mouse_move(top, 80, 10)
    assert_equal 'arrow', @manager.cursor_name(top)
  end

  # --- Windows and the manager ----------------------------------------------------------

  def test_opening_draws_the_window_and_tells_the_display_hook
    shown = []
    top = window(pt(30, 20))
    top.display_hook = ->(form) { shown << form }
    top.add_subview(SolidView.new(Color.red, Rectangle.from(0, 0, 10, 10)))
    top.open(@manager)
    assert_equal 1, shown.size
    assert_equal [30, 20], [shown.first.width, shown.first.height]
    assert_equal 0xFF0000, shown.first[0, 0]
    assert_same shown.first, top.form
    assert top.open?(@manager)
    assert_equal [top], @manager.windows
    @manager.refresh(top)
    assert_equal 1, shown.size, 'nothing changed, nothing redrawn'
  end

  def test_the_window_redraws_only_when_asked_and_only_what_changed
    model = Model.new
    shown = []
    top = window(pt(30, 20), model)
    top.display_hook = ->(form) { shown << form }
    child = top.add_subview(SolidView.new(Color.red, Rectangle.from(0, 0, 10, 10)))
    top.open(@manager)
    model.changed
    @manager.refresh_all
    assert_equal 2, shown.size
    @manager.refresh_all
    assert_equal 2, shown.size
    child.invalidate
    @manager.refresh_all
    assert_equal 3, shown.size, 'invalidating any subview redraws the window'
  end

  def test_the_opener_hook_puts_windows_on_screen
    opened = []
    @manager.opener = ->(view) { opened << view }
    top = window
    top.open(@manager)
    assert_equal [top], opened
    assert_equal top, top.open(@manager), 'opening twice does not duplicate it'
    assert_equal [top], @manager.windows
  end

  def test_closing_a_window_releases_it
    model = Model.new
    closed = []
    top = window(pt(40, 40), model)
    top.close_hook = -> { closed << :closed }
    top.open(@manager)
    top.close(@manager)
    assert_empty @manager.windows
    assert_empty model.dependents
    assert_equal [:closed], closed
    refute top.open?(@manager)
    top.close(@manager) # closing again is harmless
    assert_equal [:closed], closed
  end

  def test_events_for_a_closed_window_do_no_harm
    top = window
    top.open(@manager)
    top.close(@manager)
    @manager.mouse_down(top, 1, 1, :red)
    @manager.key(top, 'x')
    @manager.mouse_leave(top)
  end

  def test_form_show_opens_a_window_that_follows_the_form
    form = Form.new(40, 30)
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      view = form.show('My picture')
      assert_equal 'My picture', view.label
      assert_equal [40, 30], [view.form.width, view.form.height]
      assert_equal 0xFFFFFF, view.form[5, 5]
      form.fill(Rectangle.from(0, 0, 10, 10), Color.red)
      form.changed(:pixels)
      manager.refresh_all
      assert_equal 0xFF0000, view.form[5, 5], 'changing the Form and telling its dependents redraws the window'
      assert_kind_of FormView, view.subviews.first
    end
  end
end
