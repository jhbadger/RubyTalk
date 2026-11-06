# frozen_string_literal: true

# BitBlt, Smalltalk-80's one graphics primitive: copy a rectangle of a source Form into a destination
# Form, combining the two with one of 16 rules, optionally through a halftone pattern, clipped to a
# rectangle. Everything else (Form#fill, Pen, Path, text) is built on it.
#
#   blt = BitBlt.new(screen, source: stamp, rule: BitBlt::UNDER)
#   blt.copy(stamp.bounds, to: Point.new(10, 20))
#
# The rule numbers are the Blue Book's. They combine "ink": BLACK counts as 1 bits and white as 0 bits,
# as on the original 1-bit displays, so UNDER (source OR destination) paints black shapes over anything,
# ERASE removes a shape, REVERSE (XOR) draws something that a second draw undoes. Colours are combined
# bit by bit on their red, green and blue values.
#
# With no source the halftone is the source (a 1x1 colour fills a solid area, a larger pattern tiles,
# aligned to the destination Form's origin); with both, the source is ANDed with the halftone first.
class BitBlt
  CLEAR = 0               # all zeros
  AND = 1                 # source AND destination
  SOURCE_AND_NOT_DEST = 2
  OVER = 3                # source (replace)
  ERASE = 4               # NOT source AND destination
  NO_OP = 5               # destination
  REVERSE = 6             # source XOR destination
  UNDER = 7               # source OR destination
  NOR = 8
  EQUIV = 9
  INVERT = 10             # NOT destination
  SOURCE_OR_NOT_DEST = 11
  NOT_SOURCE = 12
  NOT_SOURCE_OR_DEST = 13
  NAND = 14
  SET = 15                # all ones

  MASK = 0xFFFFFF

  attr_accessor :dest_form, :source_form, :clip_rect
  attr_reader :rule, :halftone
  attr_accessor :dest_x, :dest_y, :source_x, :source_y, :width, :height

  # +halftone+ may be a Form, or anything Color.coerce accepts (a solid colour).
  def initialize(dest_form, source: nil, halftone: nil, rule: OVER, clip: nil)
    @dest_form = dest_form
    @source_form = source
    self.halftone = halftone
    self.rule = rule
    @clip_rect = clip
    @dest_x = @dest_y = @source_x = @source_y = 0
    @width = dest_form.width
    @height = dest_form.height
  end

  def rule=(value)
    raise ArgumentError, "a BitBlt rule is 0 to 15, not #{value.inspect}" unless value.is_a?(Integer) && (0..15).cover?(value)

    @rule = value
  end

  def halftone=(value)
    @halftone = case value
                when nil, Form then value
                else Form.new(1, 1, Color.coerce(value))
                end
  end

  def dest_origin=(point)
    @dest_x = point.x
    @dest_y = point.y
  end

  def source_origin=(point)
    @source_x = point.x
    @source_y = point.y
  end

  def extent=(point)
    @width = point.x
    @height = point.y
  end

  # The area of the source to copy.
  def source_rect=(rectangle)
    self.source_origin = rectangle.origin
    self.extent = rectangle.extent
  end

  # The area of the destination to fill or copy into (its size also sets the extent).
  def dest_rect=(rectangle)
    self.dest_origin = rectangle.origin
    self.extent = rectangle.extent
  end

  # Copy +source_rect+ of the source Form so that its top-left lands at +to+.
  def copy(source_rect, to:)
    self.source_rect = source_rect
    self.dest_origin = to
    copy_bits
  end

  # Fill +dest_rect+ from the halftone (the source is ignored).
  def fill(dest_rect)
    saved = @source_form
    @source_form = nil
    self.dest_rect = dest_rect
    copy_bits
  ensure
    @source_form = saved
  end

  # Combine one source and one destination value (each 0..0xFFFFFF of "ink") by +rule+.
  def self.combine(rule, source, dest)
    case rule
    when 0 then 0
    when 1 then source & dest
    when 2 then source & (dest ^ MASK)
    when 3 then source
    when 4 then (source ^ MASK) & dest
    when 5 then dest
    when 6 then source ^ dest
    when 7 then source | dest
    when 8 then (source ^ MASK) & (dest ^ MASK)
    when 9 then (source ^ dest) ^ MASK
    when 10 then dest ^ MASK
    when 11 then source | (dest ^ MASK)
    when 12 then source ^ MASK
    when 13 then (source ^ MASK) | dest
    when 14 then (source & dest) ^ MASK
    else MASK
    end
  end

  # Do the copy. Returns self.
  def copy_bits
    return self if @rule == NO_OP

    area = clipped_area or return self
    dx, dy, sx, sy, w, h = area
    # Read the source first, so copying a Form onto itself (scrolling) cannot smear.
    source_rows = @source_form && Array.new(h) { |row| @source_form.row(sy + row, sx, w) }
    h.times do |row|
      y = dy + row
      store_row(dx, y, w, source_rows && source_rows[row], halftone_row(dx, y, w))
    end
    self
  end

  private

  # [dest_x, dest_y, source_x, source_y, width, height] after clipping to the destination, the clip
  # rectangle and the source; nil if nothing is left.
  def clipped_area
    clip = Rectangle.new(Point.new(0, 0), Point.new(@dest_form.width, @dest_form.height))
    clip = clip.intersect(@clip_rect) if @clip_rect
    dx = @dest_x
    dy = @dest_y
    sx = @source_x
    sy = @source_y
    w = @width
    h = @height
    left = [dx, clip.left].max
    top = [dy, clip.top].max
    right = [dx + w, clip.right].min
    bottom = [dy + h, clip.bottom].min
    return nil if right <= left || bottom <= top

    sx += left - dx
    sy += top - dy
    dx = left
    dy = top
    w = right - left
    h = bottom - top
    if @source_form
      sx, dx, w = clip_to_source(sx, dx, w, @source_form.width)
      sy, dy, h = clip_to_source(sy, dy, h, @source_form.height)
      return nil if w <= 0 || h <= 0
    end
    [dx, dy, sx, sy, w, h]
  end

  # Keep the source span 0...limit by trimming the copy from either end.
  def clip_to_source(src, dest, length, limit)
    if src.negative?
      dest -= src
      length += src
      src = 0
    end
    length = limit - src if src + length > limit
    [src, dest, length]
  end

  # The halftone's pixels for dest columns x...x+w on row y, tiled from the destination origin; nil if none.
  def halftone_row(x, y, w)
    return nil unless @halftone

    tile_w = @halftone.width
    tile_row = @halftone.row(y % @halftone.height, 0, tile_w)
    Array.new(w) { |i| tile_row[(x + i) % tile_w] }
  end

  def store_row(dx, y, w, source, halftone)
    if @rule == OVER && !(source && halftone)
      @dest_form.set_row(y, dx, source || halftone || Array.new(w, 0)) # default ink is black
    else
      dest = @dest_form.row(y, dx, w)
      @dest_form.set_row(y, dx, Array.new(w) { |i| combine_pixels(source && source[i], halftone && halftone[i], dest[i]) })
    end
  end

  def combine_pixels(source_pixel, halftone_pixel, dest_pixel)
    source = if source_pixel && halftone_pixel then (source_pixel ^ MASK) & (halftone_pixel ^ MASK)
             elsif source_pixel then source_pixel ^ MASK
             elsif halftone_pixel then halftone_pixel ^ MASK
             else MASK
             end
    self.class.combine(@rule, source, dest_pixel ^ MASK) ^ MASK
  end
end
