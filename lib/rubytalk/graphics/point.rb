# frozen_string_literal: true

# A point in the plane: Smalltalk-80's Point (written `3@4` there, Point.new(3, 4) here). Immutable.
# Arithmetic works with another Point (coordinate by coordinate) or a number (applied to both).
#
#   Point.new(3, 4) + Point.new(1, 1)   # 4@5
#   Point.new(3, 4) * 2                 # 6@8
#   2 * Point.new(3, 4)                 # 6@8
#   3.at(4)                             # 3@4
class Point
  attr_reader :x, :y

  # A point at +radius+ from the origin, +degrees+ clockwise from east (the y axis points down).
  def self.polar(radius, degrees)
    radians = degrees * Math::PI / 180
    new(radius * Math.cos(radians), radius * Math.sin(radians))
  end

  def initialize(x = 0, y = 0)
    @x = x
    @y = y
    freeze
  end

  def +(other)
    combine(other) { |a, b| a + b }
  end

  def -(other)
    combine(other) { |a, b| a - b }
  end

  def *(other)
    combine(other) { |a, b| a * b }
  end

  def /(other)
    combine(other) { |a, b| a / b }
  end

  # Floor division (Smalltalk's //).
  def div(other)
    combine(other) { |a, b| a.div(b) }
  end

  def -@
    Point.new(-@x, -@y)
  end
  alias negated -@

  # So that `2 * point` works.
  def coerce(number)
    [Point.new(number, number), self]
  end

  # Both coordinates compare (a partial order, as in Smalltalk): a point is less than another only
  # if it is left of and above it.
  def <(other)
    @x < other.x && @y < other.y
  end

  def <=(other)
    @x <= other.x && @y <= other.y
  end

  def >(other)
    @x > other.x && @y > other.y
  end

  def >=(other)
    @x >= other.x && @y >= other.y
  end

  def max(other)
    Point.new([@x, other.x].max, [@y, other.y].max)
  end

  def min(other)
    Point.new([@x, other.x].min, [@y, other.y].min)
  end

  def abs
    Point.new(@x.abs, @y.abs)
  end

  def rounded
    Point.new(@x.round, @y.round)
  end

  def truncated
    Point.new(@x.to_i, @y.to_i)
  end

  def transpose
    Point.new(@y, @x)
  end

  def dot(other)
    (@x * other.x) + (@y * other.y)
  end

  def dist(other)
    Math.hypot(@x - other.x, @y - other.y)
  end

  # Distance from the origin.
  def r
    Math.hypot(@x, @y)
  end

  # Angle in degrees, clockwise from east.
  def theta
    Math.atan2(@y, @x) * 180 / Math::PI
  end

  # The rectangle with this point as origin and +other+ as corner.
  def corner(other)
    Rectangle.new(self, other)
  end

  # The rectangle with this point as origin and +size+ (a Point) as extent.
  def extent(size)
    Rectangle.origin_extent(self, size)
  end

  def to_a
    [@x, @y]
  end

  def ==(other)
    other.is_a?(Point) && @x == other.x && @y == other.y
  end
  alias eql? ==

  def hash
    [@x, @y].hash
  end

  def to_s
    "#{@x}@#{@y}"
  end
  alias inspect to_s

  private

  def combine(other)
    case other
    when Point then Point.new(yield(@x, other.x), yield(@y, other.y))
    when Numeric then Point.new(yield(@x, other), yield(@y, other))
    else raise TypeError, "can't combine a Point with #{other.class}"
    end
  end
end

class Numeric
  # Smalltalk's `x@y`: 3.at(4) is the point 3@4.
  def at(y)
    Point.new(self, y)
  end
end
