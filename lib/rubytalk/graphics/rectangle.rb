# frozen_string_literal: true

# A rectangle given by its top-left corner (origin) and its bottom-right corner (corner), like
# Smalltalk-80's Rectangle. The origin is inside, the corner just outside, so a 10 by 10 rectangle at
# 0@0 covers the pixels 0 to 9. Immutable: every operation returns a new Rectangle.
class Rectangle
  attr_reader :origin, :corner

  def self.origin_extent(origin, extent)
    new(origin, origin + extent)
  end

  def self.from(x, y, width, height)
    new(Point.new(x, y), Point.new(x + width, y + height))
  end

  def self.left_top_right_bottom(left, top, right, bottom)
    new(Point.new(left, top), Point.new(right, bottom))
  end

  def initialize(origin, corner)
    @origin = origin
    @corner = corner
    freeze
  end

  def left
    @origin.x
  end

  def top
    @origin.y
  end

  def right
    @corner.x
  end

  def bottom
    @corner.y
  end

  def width
    @corner.x - @origin.x
  end

  def height
    @corner.y - @origin.y
  end

  def extent
    @corner - @origin
  end

  def area
    width * height
  end

  def center
    (@origin + @corner) / 2
  end

  def top_left
    @origin
  end

  def bottom_right
    @corner
  end

  def top_right
    Point.new(right, top)
  end

  def bottom_left
    Point.new(left, bottom)
  end

  # Nothing inside (no width or no height).
  def empty?
    width <= 0 || height <= 0
  end

  # A Point is inside if origin <= point < corner; a Rectangle if it lies wholly within this one.
  def contains?(thing)
    case thing
    when Point then thing.x >= left && thing.x < right && thing.y >= top && thing.y < bottom
    when Rectangle then thing.left >= left && thing.top >= top && thing.right <= right && thing.bottom <= bottom
    else raise TypeError, "a Rectangle can contain a Point or a Rectangle, not #{thing.class}"
    end
  end

  # Do the two share any area?
  def intersects?(other)
    left < other.right && other.left < right && top < other.bottom && other.top < bottom
  end

  # The overlap (check #empty? when they may not intersect).
  def intersect(other)
    Rectangle.new(@origin.max(other.origin), @corner.min(other.corner))
  end

  # The smallest rectangle containing both.
  def merge(other)
    Rectangle.new(@origin.min(other.origin), @corner.max(other.corner))
  end

  def translate_by(delta)
    Rectangle.new(@origin + delta, @corner + delta)
  end

  # Grow every side by a number, each axis by a Point, or each side by a Rectangle's four edges.
  def expand_by(delta)
    case delta
    when Rectangle then Rectangle.new(@origin - delta.origin, @corner + delta.corner)
    else Rectangle.new(@origin - delta, @corner + delta)
    end
  end

  def inset_by(delta)
    case delta
    when Rectangle then Rectangle.new(@origin + delta.origin, @corner - delta.corner)
    else Rectangle.new(@origin + delta, @corner - delta)
    end
  end

  def scale_by(factor)
    Rectangle.new(@origin * factor, @corner * factor)
  end

  def rounded
    Rectangle.new(@origin.rounded, @corner.rounded)
  end

  # The same size, with the given point as its centre.
  def center_at(point)
    translate_by(point - center)
  end

  def with_origin(origin)
    Rectangle.origin_extent(origin, extent)
  end

  def ==(other)
    other.is_a?(Rectangle) && @origin == other.origin && @corner == other.corner
  end
  alias eql? ==

  def hash
    [@origin, @corner].hash
  end

  def to_s
    "#{@origin} corner: #{@corner}"
  end
  alias inspect to_s
end
