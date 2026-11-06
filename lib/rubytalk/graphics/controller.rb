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
  def key_pressed(char, keysym = nil); end

  def control_initialize; end

  def control_terminate; end

  def control_activity; end
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

# Clicking a row of a list view selects it.
class ListController < Controller
  def mouse_down(point, button)
    view.select_at(point) if button == :red
  end
end
