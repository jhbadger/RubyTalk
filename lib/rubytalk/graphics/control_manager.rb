# frozen_string_literal: true

# The window manager: Smalltalk-80's ControlManager (ScheduledControllers). It knows the open windows
# (top views) and turns the events a window reports (mouse down/up/move at x, y in the window; a key) into
# calls on the controller of the view under the pointer, in that view's coordinates. After each event it
# redraws any window whose views asked for it. The Tk windows call these methods; tests can call them
# directly to simulate a user, with no display at all.
#
#   manager = ControlManager.new
#   window.open(manager)
#   manager.mouse_down(window, 30, 20, :red)
#   manager.mouse_up(window, 30, 20, :red)
class ControlManager
  # The shared manager, as in Smalltalk's single ScheduledControllers.
  def self.instance
    @instance ||= new
  end

  attr_reader :windows, :sensor
  # Called with a window to put it on screen (the Tk layer sets this). Without it windows are only
  # drawn into their Forms, which is what tests use.
  attr_accessor :opener

  def initialize
    @windows = []
    @sensor = InputSensor.new
    @opener = nil
    @active = {}   # window => controller the pointer is over
    @pressed = {}  # window => [view, controller] that got the mouse button down (it keeps the mouse)
    @focus = {}    # window => controller that has the keyboard (see Controller#wants_keyboard_focus?)
    @last_click = nil
    @clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  end

  # How quickly (seconds) and how close (pixels) a second press must be to count as a double click.
  DOUBLE_CLICK_TIME = 0.4
  DOUBLE_CLICK_DISTANCE = 4

  # The time source for click counting (tests replace it).
  attr_accessor :clock

  # The controller that currently has the keyboard in +window+, if any.
  def focus_controller(window)
    @focus[window]
  end

  def open(window)
    @windows << window unless @windows.include?(window)
    @opener&.call(window)
    refresh(window)
    window
  end

  def close(window)
    return unless @windows.delete(window)

    @active.delete(window)
    @pressed.delete(window)
    @focus.delete(window)
    window.release
    window.close_hook&.call
  end

  # --- events from a window --------------------------------------------------

  # +state+ is Tk's modifier bit mask (shift is 1, control 4), read by controllers through the sensor.
  def mouse_down(window, x, y, button, state = 0)
    guarded(window) do
      point = Point.new(x, y)
      @sensor.modifiers = state
      @sensor.move_to(point)
      @sensor.press(button)
      @sensor.click_count = count_click(point, button)
      track(window, point)
      view, local = window.view_at(point)
      controller = view.controller
      focus(window, controller) if controller.wants_keyboard_focus?
      @pressed[window] = [view, controller]
      deliver(controller) { |c| c.mouse_down(local, button) }
    end
  end

  def mouse_move(window, x, y)
    guarded(window) do
      point = Point.new(x, y)
      @sensor.move_to(point)
      track(window, point)
      if (captured = @pressed[window])
        view, controller = captured
        deliver(controller) { |c| c.mouse_move(view.to_local(point)) }
      else
        view, local = window.view_at(point)
        deliver(view.controller) { |controller| controller.mouse_move(local) }
      end
    end
  end

  def mouse_up(window, x, y, button)
    guarded(window) do
      point = Point.new(x, y)
      @sensor.move_to(point)
      view, controller = @pressed[window] || window.view_at(point).then { |v, _| [v, v.controller] }
      deliver(controller) { |c| c.mouse_up(view.to_local(point), button) }
      @sensor.release(button)
      @pressed.delete(window) unless @sensor.any_button_pressed?
      track(window, point)
    end
  end

  # The pointer left the window.
  def mouse_leave(window)
    guarded(window) do
      previous = @active.delete(window)
      previous&.mouse_leave
    end
  end

  # A key was typed. It goes to the controller with the keyboard focus (the last text field or list
  # clicked), else to the one under the pointer, else to the window's own.
  def key(window, char, keysym = nil, state = 0)
    guarded(window) do
      @sensor.modifiers = state
      @sensor.key_pressed(char)
      target = @focus[window] || @active[window] || window.controller
      deliver(target) { |controller| controller.key_pressed(char, keysym) }
    end
  end

  # Cmd-<key> (Ctrl-<key> off a Mac), e.g. "c": to the same controller as typing. Returns true if it was
  # handled.
  def command_key(window, keysym)
    handled = false
    guarded(window) do
      target = @focus[window] || @active[window] || window.controller
      deliver(target) { |controller| handled = controller.command_key(keysym) ? true : false }
    end
    handled
  end

  # The wheel turned with the pointer at x, y; +lines+ is positive for down.
  def mouse_wheel(window, x, y, lines)
    guarded(window) do
      view, local = window.view_at(Point.new(x, y))
      deliver(view.controller) { |controller| controller.mouse_wheel(local, lines) }
    end
  end

  # The Tk name of the cursor to show over the window now (the view under the pointer may set one).
  def cursor_name(window)
    view = @active[window]&.view
    (view&.cursor || Cursor.normal).tk_name
  end

  # --- drawing -----------------------------------------------------------------

  # Redraw +window+ if any of its views asked.
  def refresh(window)
    window.redisplay if window.invalidated
  end

  def refresh_all
    @windows.dup.each do |window|
      refresh(window)
    rescue StandardError => e
      report(window, e)
    end
  end

  private

  # Work out which controller the pointer is over now, telling the old one it left and the new one it entered.
  def track(window, point)
    view, = window.view_at(point)
    current = view.controller
    previous = @active[window]
    return if previous.equal?(current)

    previous&.mouse_leave
    @active[window] = current
    current.mouse_enter
  end

  def deliver(controller)
    yield controller
    controller.control_activity
  end

  # Give +controller+ the keyboard (telling the one that had it).
  def focus(window, controller)
    previous = @focus[window]
    return if previous.equal?(controller)

    previous&.focus_lost
    @focus[window] = controller
    controller.focus_gained
  end

  # 1, 2 or 3: how many presses in a row at the same place, quickly enough to be a double or triple click.
  def count_click(point, button)
    now = @clock.call
    last = @last_click
    count = if last && last[:button] == button && now - last[:time] <= DOUBLE_CLICK_TIME &&
               (point.x - last[:point].x).abs <= DOUBLE_CLICK_DISTANCE &&
               (point.y - last[:point].y).abs <= DOUBLE_CLICK_DISTANCE
              [last[:count] + 1, 3].min
            else
              1
            end
    @last_click = { time: now, point: point, button: button, count: count }
    count
  end

  # Run an event handler: an error in a controller is reported in the Transcript, never raised into Tk.
  def guarded(window)
    yield
    refresh(window)
  rescue StandardError => e
    report(window, e)
  end

  def report(window, error)
    ::Transcript.show_cr("Error in the window '#{window.label}': #{RubyTalk::Evaluator.format_error(error)}")
  end
end
