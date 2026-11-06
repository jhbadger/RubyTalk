# frozen_string_literal: true

require 'zlib'

# A bitmap: a rectangle of pixels you can draw into and copy between, Smalltalk-80's Form. Each pixel is
# an integer 0xRRGGBB (see Color). New Forms are white. Coordinates start at 0@0 at the top left; reading
# or writing outside the Form is ignored (clipped), as in Smalltalk.
#
#   form = Form.new(200, 100)
#   form.fill(Rectangle.from(10, 10, 50, 30), Color.red)
#   pen = Pen.new(form)
#   pen.polygon(5, 40)
#   form.show              # open it in a window
#
# Forms keep a list of dependents (see Dependents): call #changed after drawing to refresh views of it.
class Form
  include Dependents

  attr_reader :width, :height

  def initialize(width, height, color = Color.white)
    unless width.is_a?(Integer) && height.is_a?(Integer) && width >= 0 && height >= 0
      raise ArgumentError, "a Form needs whole, non-negative width and height, not #{width.inspect} x #{height.inspect}"
    end

    @width = width
    @height = height
    @pixels = Array.new(width * height, Color.coerce(color).to_pixel)
  end

  def initialize_copy(other)
    super
    @pixels = other.pixels.dup
    @dependents = nil
  end

  def self.extent(point, color = Color.white)
    new(point.x, point.y, color)
  end

  # Lines of text as a bitmap: +ink+ characters are drawn in ink_color, everything else in paper_color.
  def self.from_ascii(lines, ink: '#', ink_color: Color.black, paper_color: Color.white)
    rows = lines.is_a?(String) ? lines.lines.map(&:chomp) : lines
    form = new(rows.map(&:size).max || 0, rows.size, paper_color)
    rows.each_with_index do |row, y|
      row.each_char.with_index { |char, x| form[x, y] = ink_color if char == ink }
    end
    form
  end

  # Read a PPM image (binary P6 or text P3).
  def self.from_ppm(data)
    data = data.b
    tokens = []
    position = 0
    magic = data[0, 2]
    raise ArgumentError, 'not a PPM image (expected P6 or P3)' unless %w[P6 P3].include?(magic)

    position = 2
    while tokens.size < 3
      position += 1 while data[position]&.match?(/\s/)
      if data[position] == '#'
        position += 1 until data[position].nil? || data[position] == "\n"
      else
        start = position
        position += 1 while data[position] && !data[position].match?(/\s/)
        tokens << data[start...position].to_i
      end
    end
    width, height, max = tokens
    form = new(width, height)
    scale = 255.0 / max
    values =
      if magic == 'P6'
        data.byteslice(position + 1, width * height * 3).unpack('C*')
      else
        data[position..].split.map(&:to_i)
      end
    pixels = Array.new(width * height) do |index|
      red, green, blue = values[index * 3, 3].map { |value| (value * scale).round }
      (red << 16) | (green << 8) | blue
    end
    form.set_row(0, 0, pixels) unless pixels.empty?
    form
  end

  def bounds
    Rectangle.new(Point.new(0, 0), Point.new(@width, @height))
  end

  def extent
    Point.new(@width, @height)
  end

  # The pixel (0xRRGGBB) at x, y, or nil outside the Form.
  def [](x, y)
    return nil unless x.between?(0, @width - 1) && y.between?(0, @height - 1)

    @pixels[(y * @width) + x]
  end

  def pixel_at(point)
    self[point.x, point.y]
  end

  # Set one pixel to a Color or pixel value (ignored outside the Form).
  def []=(x, y, color)
    return color unless x.between?(0, @width - 1) && y.between?(0, @height - 1)

    @pixels[(y * @width) + x] = color.is_a?(Integer) ? color : Color.coerce(color).to_pixel
  end

  # --- rows (used by BitBlt) ---------------------------------------------------

  def row(y, x, count)
    @pixels[(y * @width) + x, count]
  end

  def set_row(y, x, values)
    @pixels[(y * @width) + x, values.size] = values
  end

  def pixels
    @pixels
  end
  protected :pixels

  # --- drawing -----------------------------------------------------------------

  # Fill +rectangle+ (default: all) with a colour or a halftone Form, combining by +rule+.
  def fill(rectangle = nil, color = Color.black, rule: BitBlt::OVER)
    blt = BitBlt.new(self, halftone: color.is_a?(Form) ? color : Color.coerce(color), rule: rule)
    blt.fill(rectangle || bounds)
    self
  end

  def clear(color = Color.white)
    @pixels.fill(Color.coerce(color).to_pixel)
    self
  end

  # Copy +source_rect+ (default: all) of +source+ so its top-left lands at +to+.
  def copy_from(source, source_rect = nil, to: Point.new(0, 0), rule: BitBlt::OVER, halftone: nil)
    BitBlt.new(self, source: source, rule: rule, halftone: halftone).copy(source_rect || source.bounds, to: to)
    self
  end

  # A new Form holding a copy of +rectangle+ of this one.
  def copy(rectangle = nil)
    area = rectangle || bounds
    result = Form.new([area.width, 0].max, [area.height, 0].max)
    result.copy_from(self, area)
  end

  # Swap black and white (invert every colour) in +rectangle+ (default: all).
  def reverse(rectangle = nil)
    BitBlt.new(self, rule: BitBlt::INVERT).fill(rectangle || bounds)
    self
  end

  # A frame of the given thickness just inside +rectangle+.
  def border(rectangle = nil, thickness = 1, color = Color.black)
    area = rectangle || bounds
    inner = area.inset_by(thickness)
    fill(Rectangle.left_top_right_bottom(area.left, area.top, area.right, inner.top), color)
    fill(Rectangle.left_top_right_bottom(area.left, inner.bottom, area.right, area.bottom), color)
    fill(Rectangle.left_top_right_bottom(area.left, inner.top, inner.left, inner.bottom), color)
    fill(Rectangle.left_top_right_bottom(inner.right, inner.top, area.right, inner.bottom), color)
    self
  end

  # Draw text with a bitmap font (Font.default); +at+ is the top-left of the text.
  def draw_string(string, at, color: Color.black, font: Font.default, scale: 1)
    font.draw(self, string, at, color: color, scale: scale)
    self
  end

  # --- conversion --------------------------------------------------------------

  # As rows of characters: +ink+ where the pixel is +ink_color+, +paper+ elsewhere.
  def to_ascii(ink: '#', paper: '.', ink_color: Color.black)
    pixel = Color.coerce(ink_color).to_pixel
    Array.new(@height) { |y| row(y, 0, @width).map { |value| value == pixel ? ink : paper }.join }
  end

  # The raw colour bytes, three per pixel (red, green, blue), row by row.
  def to_rgb
    @pixels.flat_map { |pixel| [(pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF] }.pack('C*')
  end

  def to_ppm
    "P6\n#{@width} #{@height}\n255\n".b + to_rgb
  end

  # A PNG file (8-bit RGBA). Tk shows Forms by loading this.
  def to_png
    raw = ''.b
    @height.times do |y|
      raw << "\0".b << row(y, 0, @width).map { |pixel| (pixel << 8) | 0xFF }.pack('N*')
    end
    "\x89PNG\r\n\x1a\n".b + png_chunk('IHDR', [@width, @height, 8, 6, 0, 0, 0].pack('NNCCCCC')) +
      png_chunk('IDAT', Zlib::Deflate.deflate(raw, 6)) + png_chunk('IEND', '')
  end

  def ==(other)
    other.is_a?(Form) && @width == other.width && @height == other.height && @pixels == other.pixels
  end

  def to_s
    "a Form(#{@width}x#{@height})"
  end
  alias inspect to_s

  # Open this Form in a window (needs the RubyTalk windows). Returns the window's view.
  def show(label = 'Form')
    view = StandardSystemView.new(label, self, Point.new([@width, 1].max, [@height, 1].max))
    view.add_subview(FormView.new(self, view.local_bounds))
    view.open
  end

  private

  def png_chunk(tag, data)
    [data.bytesize].pack('N') + tag.b + data.b + [Zlib.crc32(tag.b + data.b)].pack('N')
  end
end
