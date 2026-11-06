# frozen_string_literal: true

# A small bitmap font for drawing text into Forms (Smalltalk's TextStyle and Font, much reduced): the
# classic 5x7 ASCII font (characters 32 to 126, with descenders), each cell 6 wide and 9 tall with the
# spacing, optionally enlarged by a whole-number +scale+.
#
#   Font.default.draw(form, 'Hello', Point.new(4, 4), color: Color.blue, scale: 2)
#   Font.default.width_of('Hello', 2)
class Font
  CELL_WIDTH = 6
  CELL_HEIGHT = 9

  # 95 glyphs from ' ' to '~', five column bytes each; bit 0 of a column is the top row, bit 7 the row
  # below the baseline (descenders).
  GLYPHS = <<~HEX.split.map { |byte| byte.to_i(16) }.each_slice(5).to_a.freeze
    00 00 00 00 00  00 00 5F 00 00  00 07 00 07 00  14 7F 14 7F 14  24 2A 7F 2A 12  23 13 08 64 62
    36 49 56 20 50  00 08 07 03 00  00 1C 22 41 00  00 41 22 1C 00  2A 1C 7F 1C 2A  08 08 3E 08 08
    00 80 70 30 00  08 08 08 08 08  00 00 60 60 00  20 10 08 04 02
    3E 51 49 45 3E  00 42 7F 40 00  72 49 49 49 46  21 41 49 4D 33  18 14 12 7F 10
    27 45 45 45 39  3C 4A 49 49 31  41 21 11 09 07  36 49 49 49 36  46 49 49 29 1E
    00 00 14 00 00  00 40 34 00 00  00 08 14 22 41  14 14 14 14 14  00 41 22 14 08  02 01 59 09 06
    3E 41 5D 59 4E
    7C 12 11 12 7C  7F 49 49 49 36  3E 41 41 41 22  7F 41 41 41 3E  7F 49 49 49 41  7F 09 09 09 01
    3E 41 41 51 73  7F 08 08 08 7F  00 41 7F 41 00  20 40 41 3F 01  7F 08 14 22 41  7F 40 40 40 40
    7F 02 1C 02 7F  7F 04 08 10 7F  3E 41 41 41 3E  7F 09 09 09 06  3E 41 51 21 5E  7F 09 19 29 46
    26 49 49 49 32  03 01 7F 01 03  3F 40 40 40 3F  1F 20 40 20 1F  3F 40 38 40 3F  63 14 08 14 63
    03 04 78 04 03  61 59 49 4D 43
    00 7F 41 41 41  02 04 08 10 20  41 41 41 7F 00  04 02 01 02 04  40 40 40 40 40  00 01 02 04 00
    20 54 54 78 40  7F 28 44 44 38  38 44 44 44 28  38 44 44 28 7F  38 54 54 54 18  00 08 7E 09 02
    18 A4 A4 9C 78  7F 08 04 04 78  00 44 7D 40 00  20 40 40 3D 00  7F 10 28 44 00  00 41 7F 40 00
    7C 04 78 04 78  7C 08 04 04 78  38 44 44 44 38  FC 18 24 24 18  18 24 24 18 FC  7C 08 04 04 08
    48 54 54 54 24  04 04 3F 44 24  3C 40 40 20 7C  1C 20 40 20 1C  3C 40 30 40 3C  44 28 10 28 44
    4C 90 90 90 7C  44 64 54 4C 44
    00 08 36 41 00  00 00 77 00 00  00 41 36 08 00  02 01 02 04 02
  HEX

  # The shared default font.
  def self.default
    @default ||= new
  end

  # The five column bytes for +char+ ('?' for anything the font does not have).
  def glyph(char)
    index = char.ord - 32
    GLYPHS[index.between?(0, GLYPHS.size - 1) ? index : '?'.ord - 32]
  end

  # Pixel width of the widest line of +string+.
  def width_of(string, scale = 1)
    longest = string.to_s.lines.map { |line| line.chomp.size }.max || 0
    longest.zero? ? 0 : ((longest * CELL_WIDTH) - 1) * scale
  end

  # Pixel height of +string+ (all its lines).
  def height_of(string, scale = 1)
    count = [string.to_s.lines.size, 1].max
    ((count * CELL_HEIGHT) - 1) * scale
  end

  def extent_of(string, scale = 1)
    Point.new(width_of(string, scale), height_of(string, scale))
  end

  # Draw +string+ into +form+ with its top-left at +at+. Newlines start a new line.
  def draw(form, string, at, color: Color.black, scale: 1)
    pixel = Color.coerce(color).to_pixel
    string.to_s.lines.each_with_index do |line, line_number|
      top = at.y + (line_number * CELL_HEIGHT * scale)
      line.chomp.each_char.with_index do |char, column|
        draw_glyph(form, glyph(char), at.x + (column * CELL_WIDTH * scale), top, pixel, scale)
      end
    end
    form
  end

  private

  def draw_glyph(form, columns, left, top, pixel, scale)
    columns.each_with_index do |bits, column|
      8.times do |row|
        next if bits[row].zero?

        scale.times do |dy|
          scale.times { |dx| form[left + (column * scale) + dx, top + (row * scale) + dy] = pixel }
        end
      end
    end
  end
end
