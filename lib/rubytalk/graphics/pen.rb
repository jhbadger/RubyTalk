# frozen_string_literal: true

# A pen that draws on a Form, Smalltalk-80's Pen (a BitBlt that moves). It works like a turtle: it has a
# location and a direction, and `go` moves it forward, drawing a line if the pen is down.
#
#   pen = Pen.new(form)        # starts in the middle of the Form, pointing up, pen down
#   pen.color = Color.red
#   4.times { pen.go(50); pen.turn(90) }       # a square
#   pen.up; pen.goto(Point.new(10, 10)); pen.down
#
# Direction is in degrees: 0 is east, 90 is south (the y axis points down), so turn(90) turns right.
class Pen < BitBlt
  attr_reader :direction, :width

  def initialize(form, color: Color.black)
    super(form, rule: OVER)
    self.color = color
    @width = 1
    @down = true
    @x = (form.width / 2).to_f # the centre pixel
    @y = (form.height / 2).to_f
    @direction = -90.0
  end

  def color=(color)
    self.halftone = Color.coerce(color)
  end

  def color
    Color.from_pixel(halftone.row(0, 0, 1).first)
  end

  # Line thickness in pixels (the nib is a square).
  def width=(pixels)
    @width = [pixels.to_i, 1].max
  end

  def up
    @down = false
    self
  end

  def down
    @down = true
    self
  end

  def down?
    @down
  end

  def location
    Point.new(@x.round, @y.round)
  end

  # Move without drawing.
  def place(point)
    @x = point.x.to_f
    @y = point.y.to_f
    self
  end

  # Move to +point+, drawing a line if the pen is down.
  def goto(point)
    draw_line(location, Point.new(point.x.round, point.y.round)) if @down
    place(point)
  end

  # Move forward +distance+ in the current direction.
  def go(distance)
    radians = @direction * Math::PI / 180
    goto(Point.new(@x + (distance * Math.cos(radians)), @y + (distance * Math.sin(radians))))
  end

  # Turn right by +degrees+ (negative turns left).
  def turn(degrees)
    @direction = (@direction + degrees) % 360
    self
  end

  def direction=(degrees)
    @direction = degrees.to_f % 360
  end

  def north
    self.direction = -90
    self
  end

  def east
    self.direction = 0
    self
  end

  def south
    self.direction = 90
    self
  end

  def west
    self.direction = 180
    self
  end

  # Back to the middle of the Form, pointing up.
  def home
    place(Point.new(dest_form.width / 2, dest_form.height / 2))
    north
  end

  # A regular polygon: +sides+ sides of +length+ pixels, ending where it began.
  def polygon(sides, length)
    sides.times do
      go(length)
      turn(360.0 / sides)
    end
    self
  end

  # An outward spiral: +steps+ legs, each a little longer, turning +angle+ degrees between them.
  def spiral(steps, angle = 91, growth = 2)
    steps.times do |step|
      go(step * growth)
      turn(angle)
    end
    self
  end

  # A line of the pen's colour and width from one Point to another (Bresenham), whatever the pen's state.
  def draw_line(from, to)
    x = from.x.round
    y = from.y.round
    x_end = to.x.round
    y_end = to.y.round
    dx = (x_end - x).abs
    dy = -(y_end - y).abs
    step_x = x < x_end ? 1 : -1
    step_y = y < y_end ? 1 : -1
    error = dx + dy
    loop do
      stamp(x, y)
      break if x == x_end && y == y_end

      doubled = 2 * error
      if doubled >= dy
        error += dy
        x += step_x
      end
      if doubled <= dx
        error += dx
        y += step_y
      end
    end
    self
  end

  private

  # One nib-sized square centred on x, y.
  def stamp(x, y)
    half = @width / 2
    fill(Rectangle.from(x - half, y - half, @width, @width))
  end
end
