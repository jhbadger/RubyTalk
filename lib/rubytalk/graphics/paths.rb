# frozen_string_literal: true

# Paths: shapes made of points that draw themselves on a Form (Smalltalk-80's Path, Line, LinearFit,
# Arc, Circle and Spline). A Path holds control points; #outline gives the points actually joined by
# straight segments when it is drawn.
#
#   Circle.new(Point.new(50, 50), 30).display_on(form, color: Color.blue, width: 2)
#   Spline.new([Point.new(0, 0), Point.new(40, 80), Point.new(80, 0)]).display_on(form)
class Path
  attr_reader :points

  def initialize(points = [])
    @points = points.dup
  end

  def add(point)
    @points << point
    self
  end

  # The points joined by line segments when drawn. Subclasses compute theirs.
  def outline
    @points
  end

  # Draw onto +form+, shifted by +at+, with a Pen (colour, width, rule as given). Returns the path.
  def display_on(form, at: Point.new(0, 0), color: Color.black, width: 1, rule: BitBlt::OVER)
    pen = Pen.new(form, color: color)
    pen.width = width
    pen.rule = rule
    points = outline.map { |point| point + at }
    pen.draw_line(points.first, points.first) if points.size == 1
    points.each_cons(2) { |from, to| pen.draw_line(from, to) }
    self
  end

  # The smallest Rectangle containing the outline.
  def bounds
    pts = outline
    Rectangle.new(pts.reduce { |a, b| a.min(b) }, pts.reduce { |a, b| a.max(b) } + 1)
  end

  def to_s
    "a #{self.class.name}(#{@points.size} points)"
  end
  alias inspect to_s
end

# Straight segments through the points (Smalltalk's LinearFit).
class LinearFit < Path
end

# One straight segment.
class Line < Path
  def initialize(from, to)
    super([from, to])
  end

  def begin_point
    @points.first
  end

  def end_point
    @points.last
  end

  def length
    begin_point.dist(end_point)
  end
end

# Part of a circle: +sweep+ degrees from +start+ (0 is east; angles increase clockwise).
class Arc < Path
  attr_reader :center, :radius, :start, :sweep

  def initialize(center, radius, start = 0, sweep = 360)
    super([center])
    @center = center
    @radius = radius
    @start = start
    @sweep = sweep
  end

  def outline
    steps = [(@sweep.abs * Math::PI / 180 * @radius).ceil, 8].max
    Array.new(steps + 1) do |step|
      @center + Point.polar(@radius, @start + (@sweep.to_f * step / steps))
    end.map(&:rounded)
  end

  def bounds
    Rectangle.new(@center - @radius, @center + @radius + 1)
  end
end

class Circle < Arc
  def initialize(center, radius)
    super(center, radius, 0, 360)
  end
end

# A smooth curve through the control points (Catmull-Rom).
class Spline < Path
  SEGMENTS = 16

  def outline
    pts = @points
    return pts.dup if pts.size < 3

    padded = [pts.first] + pts + [pts.last]
    curve = [pts.first]
    (1...(padded.size - 2)).each do |i|
      p0, p1, p2, p3 = padded[i - 1], padded[i], padded[i + 1], padded[i + 2]
      (1..SEGMENTS).each { |step| curve << catmull_rom(p0, p1, p2, p3, step.to_f / SEGMENTS) }
    end
    curve.map(&:rounded)
  end

  private

  def catmull_rom(p0, p1, p2, p3, t)
    t2 = t * t
    t3 = t2 * t
    coordinate = lambda do |a, b, c, d|
      0.5 * ((2 * b) + ((-a + c) * t) + (((2 * a) - (5 * b) + (4 * c) - d) * t2) + ((-a + (3 * b) - (3 * c) + d) * t3))
    end
    Point.new(coordinate.call(p0.x, p1.x, p2.x, p3.x), coordinate.call(p0.y, p1.y, p2.y, p3.y))
  end
end
