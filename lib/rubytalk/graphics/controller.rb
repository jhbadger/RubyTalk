# frozen_string_literal: true

# The C of MVC: handles the mouse and keyboard for one view. In Smalltalk-80 a controller runs its own
# loop, polling the Sensor while the pointer is in its view. RubyTalk is event driven, so the same
# structure is arranged the other way round: the ControlManager sends the controller of the view under the
# pointer each event, in the view's own coordinates:
#
#   class SketchController < Controller
#     def mouse_down(point, button) = model.dot(point)
#     def mouse_move(point)
#       model.dot(point) if sensor.red_button_pressed?
#     end
#   end
#
# #control_initialize runs when the pointer enters the view, #control_terminate when it leaves, and
# #control_activity after every event (the old loop body), so Blue Book style controllers translate easily.
class Controller
  attr_accessor :model, :view

  def initialize(view = nil)
    @view = view
    @model = view&.model
  end

  def view=(view)
    @view = view
    @model = view&.model
  end

  def sensor
    ControlManager.instance.sensor
  end

  # The pointer is inside this controller's view (the Blue Book test for "I am in control").
  def control_wanted?
    !@view.nil? && @view.contains_point?(@view.to_local(sensor.cursor_point))
  end

  # --- events: override what you need. +point+ is in the view's own coordinates. ---

  def mouse_down(point, button); end

  def mouse_up(point, button); end

  # The pointer moved (also while a button is held, when the view that was pressed keeps getting it
  # even if the pointer leaves).
  def mouse_move(point); end

  def mouse_enter
    control_initialize
  end

  def mouse_leave
    control_terminate
  end

  # A key was typed. +char+ is the character ("" for keys such as the arrows), +keysym+ Tk's name for it.
  # Modifier keys are in sensor.shift_pressed? and sensor.control_pressed?.
  def key_pressed(char, keysym = nil); end

  # The wheel (or two-finger scroll) turned over the view: +lines+ is positive to scroll down.
  def mouse_wheel(point, lines); end

  # A command key combination (Cmd-C on a Mac, Ctrl-C elsewhere): +keysym+ is the key, e.g. "c". Return
  # true if it was handled.
  def command_key(keysym)
    false
  end

  # Clicking this controller's view gives it the keyboard, which then goes to it wherever the pointer is
  # (text fields want this). Others get the keys only while the pointer is over their view.
  def wants_keyboard_focus?
    false
  end

  def focus_gained; end

  def focus_lost; end

  # A PopUpMenu to show when +button+ (:red, :yellow, :blue) is pressed over the view, or nil. See
  # MouseMenuController.
  def menu_for(_button)
    nil
  end

  def control_initialize; end

  def control_terminate; end

  def control_activity; end
end

# A controller with a pop-up menu on each mouse button, Smalltalk-80's MouseMenuController. Set the menus
# (PopUpMenu objects) and the window manager shows the one for the button pressed, instead of delivering the
# press to #mouse_down:
#
#   controller.yellow_button_menu = PopUpMenu.new(['Clear', ['Undo', -> { model.undo }]]) { |i, label| ... }
class MouseMenuController < Controller
  def initialize(view = nil)
    super
    @menus = {}
  end

  def red_button_menu=(menu)
    @menus[:red] = menu
  end

  def yellow_button_menu=(menu)
    @menus[:yellow] = menu
  end

  def blue_button_menu=(menu)
    @menus[:blue] = menu
  end

  def red_button_menu
    @menus[:red]
  end

  def yellow_button_menu
    @menus[:yellow]
  end

  def blue_button_menu
    @menus[:blue]
  end

  def menu_for(button)
    @menus[button]
  end
end

# The controller of a window itself: does nothing by default (and subviews have their own).
class StandardSystemController < Controller
end

# Press the red button on a button view, release it inside to activate it.
class ButtonController < Controller
  def mouse_down(_point, button)
    return unless button == :red

    @armed = true
    view.pressed = true
  end

  def mouse_move(point)
    view.pressed = view.contains_point?(point) if @armed
  end

  def mouse_up(point, button)
    return unless button == :red && @armed

    @armed = false
    inside = view.contains_point?(point)
    view.pressed = false
    view.activate if inside
  end

  def mouse_leave
    super
  end
end

# Clicking a row of a list view selects it; the scroll bar and the wheel scroll it; after a click the keys
# Up, Down, Page Up, Page Down, Home and End move the selection.
class ListController < MouseMenuController
  def wants_keyboard_focus?
    true
  end

  def mouse_down(point, button)
    return unless button == :red

    if view.in_scrollbar?(point)
      @scrolling = true
      view.scroll_to_point(point)
    else
      view.select_at(point)
    end
  end

  def mouse_move(point)
    view.scroll_to_point(point) if @scrolling
  end

  def mouse_up(_point, _button)
    @scrolling = false
  end

  def mouse_wheel(_point, lines)
    view.scroll_by(lines)
  end

  def key_pressed(_char, keysym = nil)
    page = [view.visible_rows - 1, 1].max
    case keysym
    when 'Up' then view.move_selection(-1)
    when 'Down' then view.move_selection(1)
    when 'Prior' then view.move_selection(-page)
    when 'Next' then view.move_selection(page)
    when 'Home' then view.select_first
    when 'End' then view.select_last
    end
  end
end
