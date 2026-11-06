# frozen_string_literal: true

# A colour: red, green and blue from 0 to 255. Forms store colours as 0xRRGGBB integers
# ("pixels"); Color converts to and from them.
class Color
  attr_reader :red, :green, :blue

  NAMED = {
    black: [0, 0, 0], white: [255, 255, 255], red: [255, 0, 0], green: [0, 160, 0], blue: [0, 0, 255],
    yellow: [255, 255, 0], cyan: [0, 255, 255], magenta: [255, 0, 255], orange: [255, 140, 0],
    gray: [128, 128, 128], light_gray: [200, 200, 200], dark_gray: [80, 80, 80], brown: [139, 90, 43],
    pink: [255, 150, 190], purple: [128, 0, 160]
  }.freeze

  class << self
    NAMED.each do |name, (red, green, blue)|
      define_method(name) { new(red, green, blue) }
    end

    def from_pixel(pixel)
      new((pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF)
    end

    # "#rrggbb" or "rrggbb".
    def from_hex(text)
      digits = text.to_s.delete_prefix('#')
      raise ArgumentError, "not a colour: #{text.inspect}" unless digits.match?(/\A\h{6}\z/)

      from_pixel(digits.to_i(16))
    end

    # Gray from 0.0 (black) to 1.0 (white).
    def gray_level(fraction)
      level = (fraction.clamp(0.0, 1.0) * 255).round
      new(level, level, level)
    end

    # A Color from a Color, a pixel integer, a name (:red), or "#rrggbb".
    def coerce(value)
      case value
      when Color then value
      when Integer then from_pixel(value)
      when Symbol then NAMED.key?(value) ? public_send(value) : raise(ArgumentError, "unknown colour #{value.inspect}")
      when String then from_hex(value)
      else raise ArgumentError, "not a colour: #{value.inspect}"
      end
    end
  end

  def initialize(red, green, blue)
    @red = red.round.clamp(0, 255)
    @green = green.round.clamp(0, 255)
    @blue = blue.round.clamp(0, 255)
    freeze
  end

  def to_pixel
    (@red << 16) | (@green << 8) | @blue
  end

  def to_hex
    format('#%02x%02x%02x', @red, @green, @blue)
  end

  # Mix with +other+: 0.0 is this colour, 1.0 is the other.
  def blend(other, fraction = 0.5)
    other = Color.coerce(other)
    Color.new(@red + ((other.red - @red) * fraction), @green + ((other.green - @green) * fraction),
              @blue + ((other.blue - @blue) * fraction))
  end

  def lighter(fraction = 0.3)
    blend(Color.white, fraction)
  end

  def darker(fraction = 0.3)
    blend(Color.black, fraction)
  end

  # Perceived brightness, 0.0 to 1.0.
  def luminance
    ((0.299 * @red) + (0.587 * @green) + (0.114 * @blue)) / 255.0
  end

  def ==(other)
    other.is_a?(Color) && to_pixel == other.to_pixel
  end
  alias eql? ==

  def hash
    to_pixel.hash
  end

  def to_s
    "a Color(#{@red}, #{@green}, #{@blue})"
  end
  alias inspect to_s
end
