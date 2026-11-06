# frozen_string_literal: true

# What the user is doing with the mouse and keyboard, Smalltalk-80's InputSensor (the global `Sensor`).
# The three mouse buttons are named by colour as in Smalltalk: red is the left (selecting) button, yellow
# the middle (menu) and blue the right. Controllers read it while handling events:
#
#   def mouse_move(point)
#     draw_to(point) if sensor.red_button_pressed?
#   end
class InputSensor
  BUTTONS = %i[red yellow blue].freeze

  SHIFT = 0x1
  CONTROL = 0x4

  # The mouse position in the window it is over (window coordinates, not the view's).
  attr_reader :cursor_point, :last_key
  # The modifier keys held at the last mouse or key event (Tk's state bits), and how many times in a row
  # the last mouse button press hit the same spot (1, 2 or 3: a double or triple click).
  attr_accessor :modifiers, :click_count

  def initialize
    @cursor_point = Point.new(0, 0)
    @down = []
    @last_key = nil
    @modifiers = 0
    @click_count = 1
  end

  def shift_pressed?
    (@modifiers & SHIFT) != 0
  end

  def control_pressed?
    (@modifiers & CONTROL) != 0
  end

  def move_to(point)
    @cursor_point = point
  end

  def press(button)
    raise ArgumentError, "unknown mouse button #{button.inspect}" unless BUTTONS.include?(button)

    @down << button unless @down.include?(button)
  end

  def release(button)
    @down.delete(button)
  end

  def button_pressed?(button)
    @down.include?(button)
  end

  def red_button_pressed?
    button_pressed?(:red)
  end

  def yellow_button_pressed?
    button_pressed?(:yellow)
  end

  def blue_button_pressed?
    button_pressed?(:blue)
  end

  def any_button_pressed?
    !@down.empty?
  end

  def key_pressed(char)
    @last_key = char
  end
end
