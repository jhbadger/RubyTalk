# frozen_string_literal: true

# Tests for the graphics classes (Point, Rectangle, Color, Form, BitBlt, Pen, Paths, Font) and the
# MVC framework built on them. No display needed.
#   ruby test/test_graphics.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'zlib'
require 'rubytalk'

class GraphicsTest < Minitest::Test
  # --- Point -------------------------------------------------------------------

  def pt(x, y)
    Point.new(x, y)
  end

  def test_point_arithmetic_with_points_and_numbers
    assert_equal pt(4, 6), pt(3, 4) + pt(1, 2)
    assert_equal pt(2, 2), pt(3, 4) - pt(1, 2)
    assert_equal pt(6, 8), pt(3, 4) * 2
    assert_equal pt(6, 8), 2 * pt(3, 4)
    assert_equal pt(1.5, 2.0), pt(3, 4) / 2.0
    assert_equal pt(1, 2), pt(3, 5).div(2)
    assert_equal pt(-3, -4), -pt(3, 4)
    assert_equal pt(6, 8), pt(3, 4) * pt(2, 2)
    assert_raises(TypeError) { pt(1, 1) + 'x' }
  end

  def test_point_comparison_is_a_partial_order
    assert pt(1, 1) < pt(2, 2)
    refute pt(1, 3) < pt(2, 2), 'both coordinates must be smaller'
    assert pt(1, 1) <= pt(1, 2)
    assert pt(3, 3) > pt(2, 2)
    assert pt(2, 2) >= pt(2, 2)
    assert_equal pt(3, 5), pt(1, 5).max(pt(3, 2))
    assert_equal pt(1, 2), pt(1, 5).min(pt(3, 2))
  end

  def test_point_geometry_and_conversion
    assert_in_delta 5.0, pt(0, 0).dist(pt(3, 4))
    assert_in_delta 5.0, pt(3, 4).r
    assert_in_delta 90.0, pt(0, 1).theta
    assert_equal 11, pt(1, 2).dot(pt(3, 4))
    assert_equal pt(2, 1), pt(1, 2).transpose
    assert_equal pt(2, 4), pt(1.6, 3.5).rounded
    assert_equal pt(1, 3), pt(1.6, 3.5).truncated
    assert_equal pt(3, 4), pt(-3, 4).abs
    polar = Point.polar(10, 90)
    assert_in_delta 0.0, polar.x, 1e-9
    assert_in_delta 10.0, polar.y, 1e-9
    assert_equal pt(3, 4), 3.at(4)
    assert_equal '3@4', pt(3, 4).to_s
    assert_equal '3@4', pt(3, 4).inspect
    assert_equal [3, 4], pt(3, 4).to_a
    assert_equal pt(3, 4).hash, pt(3, 4).hash
    assert_equal({ pt(1, 2) => :a }[pt(1, 2)], :a)
    assert pt(1, 1).frozen?
  end

  # --- Rectangle -----------------------------------------------------------------

  def test_rectangle_basics
    r = Rectangle.from(10, 20, 30, 40)
    assert_equal [10, 20, 40, 60], [r.left, r.top, r.right, r.bottom]
    assert_equal [30, 40, 1200], [r.width, r.height, r.area]
    assert_equal pt(30, 40), r.extent
    assert_equal pt(25, 40), r.center
    assert_equal [pt(10, 20), pt(40, 20), pt(10, 60), pt(40, 60)], [r.top_left, r.top_right, r.bottom_left, r.bottom_right]
    assert_equal r, Rectangle.origin_extent(pt(10, 20), pt(30, 40))
    assert_equal r, pt(10, 20).corner(pt(40, 60))
    assert_equal r, pt(10, 20).extent(pt(30, 40))
    assert_equal r, Rectangle.left_top_right_bottom(10, 20, 40, 60)
    assert_equal '10@20 corner: 40@60', r.to_s
    assert r.frozen?
  end

  def test_rectangle_containment_and_intersection
    r = Rectangle.from(0, 0, 10, 10)
    assert r.contains?(pt(0, 0))
    assert r.contains?(pt(9, 9))
    refute r.contains?(pt(10, 10)), 'the corner is outside'
    assert r.contains?(Rectangle.from(2, 2, 5, 5))
    refute r.contains?(Rectangle.from(8, 8, 5, 5))
    assert_raises(TypeError) { r.contains?('x') }
    assert r.intersects?(Rectangle.from(5, 5, 10, 10))
    refute r.intersects?(Rectangle.from(10, 0, 5, 5)), 'touching is not intersecting'
    assert_equal Rectangle.from(5, 5, 5, 5), r.intersect(Rectangle.from(5, 5, 10, 10))
    assert r.intersect(Rectangle.from(20, 20, 5, 5)).empty?
    assert_equal Rectangle.from(0, 0, 15, 15), r.merge(Rectangle.from(5, 5, 10, 10))
  end

  def test_rectangle_transformations
    r = Rectangle.from(10, 10, 20, 20)
    assert_equal Rectangle.from(15, 12, 20, 20), r.translate_by(pt(5, 2))
    assert_equal Rectangle.from(8, 8, 24, 24), r.expand_by(2)
    assert_equal Rectangle.from(8, 5, 24, 30), r.expand_by(pt(2, 5))
    assert_equal Rectangle.left_top_right_bottom(8, 9, 31, 31), r.expand_by(Rectangle.new(pt(2, 1), pt(1, 1)))
    assert_equal Rectangle.from(12, 12, 16, 16), r.inset_by(2)
    assert_equal Rectangle.from(20, 20, 40, 40), r.scale_by(2)
    assert_equal Rectangle.from(0, 0, 20, 20), r.center_at(pt(10, 10))
    assert_equal Rectangle.from(0, 0, 20, 20), r.with_origin(pt(0, 0))
    assert_equal Rectangle.from(3, 4, 5, 6), Rectangle.new(pt(2.6, 3.5), pt(8.4, 10.4)).rounded
  end

  # --- Color -----------------------------------------------------------------------

  def test_colors
    assert_equal 0xFF0000, Color.red.to_pixel
    assert_equal Color.new(1, 2, 3), Color.from_pixel(0x010203)
    assert_equal Color.new(255, 255, 255), Color.new(300, 999, 1000), 'values are clamped'
    assert_equal Color.new(0, 0, 0), Color.new(-5, 0, 0)
    assert_equal Color.new(171, 205, 239), Color.from_hex('#abcdef')
    assert_equal '#abcdef', Color.from_hex('abcdef').to_hex
    assert_raises(ArgumentError) { Color.from_hex('zzz') }
    assert_equal Color.gray_level(0.5), Color.new(128, 128, 128)
    assert_equal Color.white, Color.coerce(:white)
    assert_equal Color.red, Color.coerce(0xFF0000)
    assert_equal Color.blue, Color.coerce('#0000ff')
    assert_equal Color.red, Color.coerce(Color.red)
    assert_raises(ArgumentError) { Color.coerce(:no_such_colour) }
    assert_raises(ArgumentError) { Color.coerce(3.5) }
    assert_equal Color.new(128, 0, 128), Color.red.blend(Color.blue, 0.5)
    assert_equal Color.new(255, 128, 128), Color.red.lighter(0.5)
    assert_equal Color.new(128, 0, 0), Color.red.darker(0.5)
    assert_in_delta 1.0, Color.white.luminance
    assert_in_delta 0.0, Color.black.luminance
    assert_equal({ Color.red => 1 }[Color.new(255, 0, 0)], 1)
  end

  # --- Form ----------------------------------------------------------------------------

  def test_form_pixels_and_clipping
    f = Form.new(4, 3)
    assert_equal [4, 3], [f.width, f.height]
    assert_equal pt(4, 3), f.extent
    assert_equal Rectangle.from(0, 0, 4, 3), f.bounds
    assert_equal 0xFFFFFF, f[0, 0], 'new Forms are white'
    f[1, 1] = Color.red
    assert_equal 0xFF0000, f[1, 1]
    assert_equal 0xFF0000, f.pixel_at(pt(1, 1))
    f[2, 2] = 0x00FF00
    assert_equal 0x00FF00, f[2, 2]
    assert_nil f[4, 0]
    assert_nil f[-1, 0]
    f[10, 10] = Color.red # ignored
    f[-1, -1] = Color.red
    assert_equal 'a Form(4x3)', f.to_s
    assert_raises(ArgumentError) { Form.new(-1, 2) }
    assert_raises(ArgumentError) { Form.new(2.5, 2) }
    assert_equal pt(7, 5), Form.extent(pt(7, 5)).extent
  end

  def test_form_ascii_round_trip_and_equality
    art = ['#..#', '.##.', '#..#']
    f = Form.from_ascii(art)
    assert_equal art, f.to_ascii
    assert_equal [4, 3], [f.width, f.height]
    assert_equal 0, f[0, 0]
    assert_equal Form.from_ascii(art), f
    refute_equal Form.from_ascii(['#']), f
    copy = f.dup
    copy[0, 0] = Color.white
    assert_equal 0, f[0, 0], 'a copy is independent'
    assert_equal ['#..#', '.##.', '#..#'], Form.from_ascii("#..#\n.##.\n#..#\n").to_ascii
  end

  def test_form_fill_copy_reverse_border
    f = Form.new(10, 10)
    f.fill(Rectangle.from(2, 2, 3, 3), Color.red)
    assert_equal 0xFF0000, f[2, 2]
    assert_equal 0xFF0000, f[4, 4]
    assert_equal 0xFFFFFF, f[5, 5]
    assert_equal 0xFFFFFF, f[1, 1]
    sub = f.copy(Rectangle.from(2, 2, 3, 3))
    assert_equal [3, 3], [sub.width, sub.height]
    assert_equal 9, sub.to_ascii(ink_color: Color.red).join.count('#')

    f.clear(Color.white)
    f.reverse(Rectangle.from(0, 0, 2, 2))
    assert_equal 0, f[0, 0], 'reverse turns white into black'
    f.reverse(Rectangle.from(0, 0, 2, 2))
    assert_equal 0xFFFFFF, f[0, 0], 'and back'

    f.clear
    f.border(nil, 1, Color.black)
    assert_equal 0, f[0, 0]
    assert_equal 0, f[9, 9]
    assert_equal 0, f[5, 0]
    assert_equal 0xFFFFFF, f[5, 5]
    assert_equal 36, f.to_ascii.join.count('#'), 'a one-pixel frame of a 10x10 Form is 4 * 9 pixels'
  end

  def test_form_copy_from_places_the_source
    src = Form.from_ascii(['##', '##'])
    dst = Form.new(5, 4)
    dst.copy_from(src, to: pt(1, 1))
    assert_equal ['.....', '.##..', '.##..', '.....'], dst.to_ascii
    dst.copy_from(src, Rectangle.from(0, 0, 1, 1), to: pt(4, 3))
    assert_equal '#', dst.to_ascii[3][4]
  end

  def test_form_ppm_round_trip_and_png
    f = Form.new(3, 2)
    f[0, 0] = Color.red
    f[2, 1] = Color.blue
    again = Form.from_ppm(f.to_ppm)
    assert_equal f, again
    text = "P3\n# a comment\n2 1\n255\n255 0 0  0 0 255\n"
    ascii = Form.from_ppm(text)
    assert_equal [0xFF0000, 0x0000FF], [ascii[0, 0], ascii[1, 0]]
    assert_raises(ArgumentError) { Form.from_ppm('P9 1 1 255 x') }

    png = f.to_png
    assert_equal "\x89PNG\r\n\x1a\n".b, png.byteslice(0, 8)
    width, height, depth, color = png.byteslice(16, 10).unpack('NNCC')
    assert_equal [3, 2, 8, 6], [width, height, depth, color]
    chunks = {}
    offset = 8
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1('N')
      tag = png.byteslice(offset + 4, 4)
      body = png.byteslice(offset + 8, length)
      assert_equal Zlib.crc32(tag + body), png.byteslice(offset + 8 + length, 4).unpack1('N'), "CRC of #{tag}"
      chunks[tag] = body
      offset += 12 + length
    end
    raw = Zlib::Inflate.inflate(chunks['IDAT'])
    assert_equal (3 * 4 + 1) * 2, raw.bytesize
    assert_equal [0, 255, 0, 0, 255], raw.bytes.first(5), 'filter byte, then red pixel as R G B A'
    assert_equal 3 * 2 * 3, f.to_rgb.bytesize
  end

  def test_empty_forms_are_allowed
    empty = Form.new(0, 0)
    assert_equal 0, empty.to_ascii.size
    assert_equal 'a Form(0x0)', empty.to_s
    assert Form.new(3, 3).copy(Rectangle.from(0, 0, 0, 0)).bounds.empty?
  end

  # --- BitBlt ------------------------------------------------------------------------------

  # A 1x1 Form: black is ink (1), white is paper (0), as on the original 1-bit displays.
  def dot(ink)
    Form.new(1, 1, ink ? Color.black : Color.white)
  end

  def test_all_sixteen_rules_match_the_blue_book_truth_table
    (0..15).each do |rule|
      [1, 0].each do |s|
        [1, 0].each do |d|
          dest = dot(d == 1)
          source = dot(s == 1)
          BitBlt.new(dest, source: source, rule: rule).copy(source.bounds, to: pt(0, 0))
          expected_ink = (rule >> (((1 - s) * 2) + (1 - d))) & 1
          assert_equal expected_ink == 1 ? 0x000000 : 0xFFFFFF, dest[0, 0], "rule #{rule}, source #{s}, destination #{d}"
        end
      end
    end
  end

  def test_named_rules_do_what_their_names_say
    paint = lambda do |rule, dest_color|
      dest = Form.new(1, 1, dest_color)
      BitBlt.new(dest, source: dot(true), rule: rule).copy(Rectangle.from(0, 0, 1, 1), to: pt(0, 0))
      dest[0, 0]
    end
    assert_equal 0x000000, paint.call(BitBlt::UNDER, Color.white), 'UNDER paints black over white'
    assert_equal 0x000000, paint.call(BitBlt::UNDER, Color.red), 'and over colours'
    assert_equal 0xFFFFFF, paint.call(BitBlt::ERASE, Color.black), 'ERASE removes ink'
    assert_equal 0x000000, paint.call(BitBlt::REVERSE, Color.white), 'REVERSE (xor) draws'
    assert_equal 0xFFFFFF, paint.call(BitBlt::REVERSE, Color.black), 'and a second draw undoes it'
    assert_equal 0xFF0000, paint.call(BitBlt::NO_OP, Color.red)
    assert_equal 0x000000, paint.call(BitBlt::OVER, Color.red)
    assert_equal 0xFFFFFF, paint.call(BitBlt::CLEAR, Color.red)
    assert_equal 0x000000, paint.call(BitBlt::SET, Color.red)
    assert_equal 0x00FFFF, paint.call(BitBlt::INVERT, Color.red), 'INVERT inverts each channel'
  end

  def test_bitblt_rejects_bad_rules
    assert_raises(ArgumentError) { BitBlt.new(Form.new(1, 1), rule: 16) }
    assert_raises(ArgumentError) { BitBlt.new(Form.new(1, 1), rule: 'over') }
    blt = BitBlt.new(Form.new(1, 1))
    assert_raises(ArgumentError) { blt.rule = -1 }
  end

  def test_copy_is_clipped_to_the_destination_and_the_source
    src = Form.from_ascii(['###', '###', '###'])
    dst = Form.new(4, 4)
    BitBlt.new(dst, source: src).copy(src.bounds, to: pt(3, 3))
    assert_equal ['....', '....', '....', '...#'], dst.to_ascii, 'only the part that fits'
    dst.clear
    BitBlt.new(dst, source: src).copy(src.bounds, to: pt(-2, -2))
    assert_equal ['#...', '....', '....', '....'], dst.to_ascii, 'off the top-left'
    dst.clear
    BitBlt.new(dst, source: src).copy(Rectangle.from(-1, -1, 3, 3), to: pt(0, 0))
    assert_equal ['....', '.##.', '.##.', '....'], dst.to_ascii,
                 'source pixel -1@-1 lines up with 0@0, so only the part inside the source lands'
    dst.clear
    BitBlt.new(dst, source: src).copy(Rectangle.from(1, 1, 10, 10), to: pt(0, 0))
    assert_equal ['##..', '##..', '....', '....'], dst.to_ascii
    dst.clear
    BitBlt.new(dst, source: src, clip: Rectangle.from(1, 1, 1, 1)).copy(src.bounds, to: pt(0, 0))
    assert_equal ['....', '.#..', '....', '....'], dst.to_ascii, 'the clip rectangle'
    dst.clear
    BitBlt.new(dst, source: src).copy(Rectangle.from(0, 0, 3, 3), to: pt(50, 50)) # entirely outside: nothing, no error
    assert_equal 0, dst.to_ascii.join.count('#')
  end

  def test_copying_a_form_onto_itself_scrolls_without_smearing
    form = Form.from_ascii(['#...', '.#..', '..#.', '...#'])
    BitBlt.new(form, source: form).copy(Rectangle.from(0, 0, 3, 4), to: pt(1, 0))
    assert_equal ['##..', '..#.', '...#', '....'], form.to_ascii,
                 'every row moved right by one, each from the original (a naive left-to-right copy would smear)'
    up = Form.from_ascii(['#...', '.#..', '..#.', '...#'])
    BitBlt.new(up, source: up).copy(Rectangle.from(0, 1, 4, 3), to: pt(0, 0))
    assert_equal ['.#..', '..#.', '...#', '...#'], up.to_ascii, 'scrolled up one row, the last row left as it was'
  end

  def test_halftone_fills_tiles_and_ands_with_a_source
    dst = Form.new(4, 4)
    checker = Form.from_ascii(['#.', '.#'])
    BitBlt.new(dst, halftone: checker).fill(dst.bounds)
    assert_equal ['#.#.', '.#.#', '#.#.', '.#.#'], dst.to_ascii, 'a halftone tiles'

    dst.clear
    BitBlt.new(dst, halftone: checker).fill(Rectangle.from(1, 1, 2, 2))
    assert_equal ['....', '.#..', '..#.', '....'], dst.to_ascii, 'aligned to the destination origin, not the rectangle'

    dst.clear
    solid = Form.from_ascii(['##', '##'])
    BitBlt.new(dst, source: solid, halftone: checker).copy(solid.bounds, to: pt(0, 0))
    assert_equal ['#...', '.#..', '....', '....'], dst.to_ascii, 'source AND halftone'

    dst.clear
    BitBlt.new(dst, halftone: Color.red).fill(Rectangle.from(0, 0, 2, 1))
    assert_equal [0xFF0000, 0xFF0000, 0xFFFFFF], [dst[0, 0], dst[1, 0], dst[2, 0]], 'a colour is a solid halftone'
  end

  def test_fill_with_no_halftone_is_black
    dst = Form.new(2, 2)
    BitBlt.new(dst).fill(dst.bounds)
    assert_equal 4, dst.to_ascii.join.count('#')
  end

  def test_fill_leaves_the_source_alone
    src = Form.from_ascii(['#'])
    blt = BitBlt.new(Form.new(2, 2), source: src, halftone: Color.red)
    blt.fill(Rectangle.from(0, 0, 2, 2))
    assert_same src, blt.source_form
    assert_equal 0xFF0000, blt.dest_form[1, 1]
  end

  # --- Pen -----------------------------------------------------------------------------------

  def test_pen_draws_straight_lines
    f = Form.new(10, 6)
    pen = Pen.new(f)
    pen.draw_line(pt(0, 0), pt(9, 0))
    assert_equal '#' * 10, f.to_ascii[0]
    f.clear
    pen.draw_line(pt(0, 0), pt(5, 5))
    assert_equal [0, 1, 2, 3, 4, 5], (0..5).select { |i| f[i, i] == 0 }
    f.clear
    pen.draw_line(pt(2, 1), pt(2, 4))
    assert_equal 4, f.to_ascii.join.count('#')
    f.clear
    pen.draw_line(pt(1, 1), pt(1, 1))
    assert_equal 1, f.to_ascii.join.count('#'), 'a point'
    f.clear
    pen.draw_line(pt(9, 5), pt(0, 0)) # backwards
    assert_equal 0, f[0, 0]
    assert_equal 0, f[9, 5]
  end

  def test_pen_turtle_moves_and_turns
    f = Form.new(21, 21)
    pen = Pen.new(f)
    pen.go(5)
    assert_equal pt(10, 5), pen.location, 'a new pen points up'
    pen.turn(90)
    pen.go(5)
    assert_equal pt(15, 5), pen.location, 'turn(90) turns right'
    assert_equal 0.0, pen.direction, 'north turned right is east'
    pen.west.go(2)
    assert_equal pt(13, 5), pen.location
    pen.south.go(1)
    assert_equal pt(13, 6), pen.location
    pen.east
    assert_equal 0.0, pen.direction
    pen.home
    assert_equal pt(10, 10), pen.location
    assert_equal 270.0, pen.direction % 360
  end

  def test_pen_up_down_place_and_goto
    f = Form.new(10, 10)
    pen = Pen.new(f)
    pen.up
    refute pen.down?
    pen.goto(pt(2, 2))
    assert_equal 0, f.to_ascii.join.count('#'), 'a raised pen draws nothing'
    pen.down
    assert pen.down?
    pen.goto(pt(6, 2))
    assert_equal '..#####...', f.to_ascii[2]
    pen.place(pt(0, 9))
    assert_equal pt(0, 9), pen.location
    assert_equal 5, f.to_ascii.join.count('#'), 'place does not draw'
  end

  def test_pen_closed_shapes_return_to_the_start
    f = Form.new(60, 60)
    pen = Pen.new(f)
    start = pen.location
    pen.polygon(4, 20)
    assert_equal start, pen.location
    pen.polygon(6, 10)
    assert_equal start, pen.location
    assert_operator f.to_ascii.join.count('#'), :>, 100
    assert_equal pen, pen.spiral(10)
  end

  def test_pen_colour_width_and_rule
    f = Form.new(10, 10)
    pen = Pen.new(f, color: Color.red)
    assert_equal Color.red, pen.color
    pen.color = :blue
    assert_equal Color.blue, pen.color
    pen.width = 3
    pen.draw_line(pt(5, 5), pt(5, 5))
    assert_equal 9, (0...10).sum { |y| (0...10).count { |x| f[x, y] == 0x0000FF } }, 'a 3x3 nib'
    assert_equal 3, pen.width
    pen.width = 0
    assert_equal 1, pen.width, 'at least one pixel'
    xor = Pen.new(Form.new(4, 1), color: Color.black)
    xor.rule = BitBlt::REVERSE
    xor.draw_line(pt(0, 0), pt(3, 0))
    xor.draw_line(pt(0, 0), pt(3, 0))
    assert_equal 0, xor.dest_form.to_ascii.join.count('#'), 'drawing twice with REVERSE erases'
  end

  # --- Paths ---------------------------------------------------------------------------------

  def test_line_and_linear_fit
    f = Form.new(10, 10)
    Line.new(pt(0, 0), pt(9, 0)).display_on(f)
    assert_equal '#' * 10, f.to_ascii[0]
    line = Line.new(pt(0, 0), pt(3, 4))
    assert_in_delta 5.0, line.length
    assert_equal [pt(0, 0), pt(3, 4)], [line.begin_point, line.end_point]
    f.clear
    LinearFit.new([pt(0, 0), pt(4, 0), pt(4, 4)]).display_on(f)
    assert_equal 0, f[4, 4]
    assert_equal 0, f[0, 0]
    assert_equal 9, f.to_ascii.join.count('#')
    f.clear
    Path.new.add(pt(3, 3)).display_on(f)
    assert_equal 1, f.to_ascii.join.count('#'), 'a one-point path is a dot'
    f.clear
    Line.new(pt(0, 0), pt(3, 0)).display_on(f, at: pt(2, 5), color: Color.red, width: 1)
    assert_equal 0xFF0000, f[2, 5]
    assert_equal 0xFF0000, f[5, 5]
  end

  def test_circle_and_arc
    f = Form.new(41, 41)
    Circle.new(pt(20, 20), 15).display_on(f)
    [[35, 20], [5, 20], [20, 5], [20, 35]].each { |x, y| assert_equal 0, f[x, y], "circle at #{x}@#{y}" }
    assert_equal 0xFFFFFF, f[20, 20], 'the centre is empty'
    assert_equal 0xFFFFFF, f[20, 12]
    f.clear
    Arc.new(pt(20, 20), 15, 0, 90).display_on(f)
    assert_equal 0, f[35, 20], 'an arc from east...'
    assert_equal 0, f[20, 35], '...a quarter turn clockwise to south'
    assert_equal 0xFFFFFF, f[5, 20], 'and no further'
    assert_equal Rectangle.from(5, 5, 31, 31), Circle.new(pt(20, 20), 15).bounds
    assert_equal pt(20, 20), Circle.new(pt(20, 20), 15).center
    assert_equal 15, Circle.new(pt(20, 20), 15).radius
  end

  def test_spline_passes_through_its_control_points
    controls = [pt(0, 0), pt(20, 30), pt(40, 0), pt(60, 30)]
    curve = Spline.new(controls).outline
    controls.each { |control| assert_includes curve, control }
    assert_operator curve.size, :>, controls.size * 4
    assert_equal controls.first, curve.first
    assert_equal controls.last, curve.last
    assert_equal [pt(1, 1), pt(5, 5)], Spline.new([pt(1, 1), pt(5, 5)]).outline, 'fewer than three points: straight'
    f = Form.new(70, 40)
    Spline.new(controls).display_on(f)
    assert_equal 0, f[20, 30]
  end

  def test_path_bounds_and_description
    path = LinearFit.new([pt(2, 3), pt(8, 1), pt(5, 9)])
    assert_equal Rectangle.left_top_right_bottom(2, 1, 9, 10), path.bounds
    assert_equal 'a LinearFit(3 points)', path.to_s
    assert_equal 3, path.points.size
  end

  # --- Font ----------------------------------------------------------------------------------

  def test_font_has_every_printable_ascii_glyph
    assert_equal 95, Font::GLYPHS.size
    assert(Font::GLYPHS.all? { |glyph| glyph.size == 5 })
    (32..126).each { |code| assert_equal Font::GLYPHS[code - 32], Font.default.glyph(code.chr) }
    assert_equal Font.default.glyph('?'), Font.default.glyph("é"), 'unknown characters show as ?'
  end

  def test_font_draws_known_glyphs
    f = Form.new(6, 8)
    Font.default.draw(f, 'A', pt(0, 0))
    assert_equal ['..#...', '.#.#..', '#...#.', '#...#.', '#####.', '#...#.', '#...#.', '......'], f.to_ascii

    g = Form.new(6, 8)
    Font.default.draw(g, 'g', pt(0, 0))
    assert_equal '#', g.to_ascii[7][1], 'g has a descender on the bottom row'
    shifted = Form.new(10, 12)
    Font.default.draw(shifted, 'A', pt(3, 2))
    assert_equal f.to_ascii, shifted.copy(Rectangle.from(3, 2, 6, 8)).to_ascii, 'drawn at the position asked for'
  end

  def test_font_scale_position_colour_and_metrics
    f = Form.new(30, 20)
    f.draw_string('I', pt(2, 3), color: Color.red, scale: 2)
    assert_operator f.to_ascii(ink_color: Color.red).join.count('#'), :>, 20, 'drawn in red and doubled'
    assert_equal 0xFFFFFF, f[0, 0]
    assert_equal 29, Font.default.width_of('12345')
    assert_equal 58, Font.default.width_of('12345', 2)
    assert_equal 0, Font.default.width_of('')
    assert_equal 8, Font.default.height_of('x')
    assert_equal 17, Font.default.height_of("x\ny")
    assert_equal pt(29, 17), Font.default.extent_of("12345\nab")
    multi = Form.new(20, 20)
    multi.draw_string("I\nI", pt(0, 0))
    assert_operator multi.to_ascii.join.count('#'), :>, 8
    assert(multi.to_ascii[9..].join.include?('#'), 'the second line is lower down')
    off = Form.new(5, 5)
    off.draw_string('WWW', pt(3, 3)) # partly outside: clipped, no error
    off.draw_string('x', pt(-50, -50))
  end

  # --- Cursor ---------------------------------------------------------------------------------

  def test_cursors
    assert_equal 'crosshair', Cursor.crosshair.tk_name
    assert_equal 'watch', Cursor.wait.tk_name
    assert_equal 'arrow', Cursor.normal.tk_name
    assert_equal Cursor.hand, Cursor.hand
    form = Form.new(16, 16)
    cursor = Cursor.new('dot', form, pt(8, 8))
    assert_equal [form, pt(8, 8)], [cursor.form, cursor.hot_spot]
    assert_equal 'a Cursor(dot)', cursor.to_s
  end

  # --- Dependents -----------------------------------------------------------------------------

  Watcher = Struct.new(:log) do
    def update(aspect, with)
      log << [aspect, with]
    end
  end

  def test_dependents
    form = Form.new(2, 2)
    watcher = Watcher.new([])
    other = Watcher.new([])
    form.add_dependent(watcher)
    form.add_dependent(watcher) # twice: still once
    form.add_dependent(other)
    assert_equal [watcher, other], form.dependents
    form.changed(:pixels)
    form.changed(:item, with: 7)
    form.changed
    assert_equal [[:pixels, nil], [:item, 7], [nil, nil]], watcher.log
    form.remove_dependent(other)
    form.changed(:again)
    assert_equal 3, other.log.size
    assert_equal 4, watcher.log.size
    form.release_dependents
    assert_empty form.dependents
    form.dependents << :junk # a copy: the real list is untouched
    assert_empty form.dependents
    assert_empty form.dup.dependents
  end
end

# --- The Model-View-Controller framework ----------------------------------------------------------

class MvcTest < Minitest::Test
  def setup
    Transcript.clear
    @manager = ControlManager.new
  end

  def pt(x, y)
    Point.new(x, y)
  end

  # A view that paints its whole area one colour, and records how it was drawn.
  class SolidView < View
    attr_reader :draws

    def initialize(color, bounds, model = nil)
      super(model, bounds)
      @color = color
      @draws = 0
    end

    def display_view(form)
      @draws += 1
      form.fill(nil, @color)
    end
  end

  # A controller that records everything it is sent.
  class Recorder < Controller
    attr_reader :log

    def initialize(view = nil)
      super
      @log = []
    end

    def mouse_down(point, button)
      @log << [:down, point, button]
    end

    def mouse_up(point, button)
      @log << [:up, point, button]
    end

    def mouse_move(point)
      @log << [:move, point]
    end

    def mouse_enter
      @log << :enter
      super
    end

    def mouse_leave
      @log << :leave
      super
    end

    def key_pressed(char, keysym = nil)
      @log << [:key, char, keysym]
    end

    def control_initialize
      @log << :initialize
    end

    def control_terminate
      @log << :terminate
    end

    def control_activity
      @log << :activity
    end
  end

  def window(extent = pt(100, 80), model = nil)
    StandardSystemView.new('Test', model, extent)
  end

  def with_recorder(view)
    recorder = Recorder.new(view)
    view.controller = recorder
    recorder
  end

  # --- Model and dependency --------------------------------------------------

  def test_model_changes_invalidate_the_views_that_depend_on_it
    model = Model.new
    view = window(pt(40, 40), model)
    @manager.open(view)
    refute view.invalidated, 'drawn at open'
    model.changed(:anything)
    assert view.invalidated, 'the dependent view asked for a redraw'
    @manager.refresh(view)
    refute view.invalidated
    assert_equal [view], model.dependents
  end

  def test_changing_the_model_of_a_view_moves_the_dependency
    first = Model.new
    second = Model.new
    view = View.new(first)
    view.model = second
    assert_empty first.dependents
    assert_equal [view], second.dependents
    view.model = nil
    assert_empty second.dependents
    plain = View.new(Object.new) # a model that has no dependents: fine
    assert_kind_of Object, plain.model
  end

  def test_views_can_select_what_they_react_to
    model = Model.new
    picky = Class.new(View) do
      def update(aspect, _with)
        invalidate if aspect == :wanted
      end
    end.new(model)
    top = window
    top.add_subview(picky)
    top.invalidated = false
    model.changed(:other)
    refute top.invalidated
    model.changed(:wanted)
    assert top.invalidated
  end

  # --- Views: structure and drawing ----------------------------------------------

  def test_subviews_are_drawn_at_their_bounds_in_their_own_coordinates
    top = window(pt(100, 80))
    top.background = Color.white
    red = SolidView.new(Color.red, Rectangle.from(10, 20, 30, 10))
    top.add_subview(red)
    form = top.render
    assert_equal [100, 80], [form.width, form.height]
    assert_equal 0xFF0000, form[10, 20]
    assert_equal 0xFF0000, form[39, 29]
    assert_equal 0xFFFFFF, form[40, 29], 'just outside'
    assert_equal 0xFFFFFF, form[9, 20]
    assert_equal 0xFFFFFF, form[10, 30]
  end

  def test_a_view_cannot_draw_outside_its_bounds
    top = window(pt(60, 60))
    greedy = Class.new(View) do
      def display_view(form)
        form.fill(Rectangle.from(-50, -50, 500, 500), Color.blue) # far bigger than the view
      end
    end.new(nil, Rectangle.from(20, 20, 20, 20))
    top.add_subview(greedy)
    form = top.render
    assert_equal 0x0000FF, form[20, 20]
    assert_equal 0x0000FF, form[39, 39]
    assert_equal 0xFFFFFF, form[19, 20]
    assert_equal 0xFFFFFF, form[40, 40]
  end

  def test_nested_views_stack_in_order_and_later_ones_are_on_top
    top = window(pt(100, 100))
    outer = top.add_subview(SolidView.new(Color.green, Rectangle.from(10, 10, 60, 60)))
    inner = outer.add_subview(SolidView.new(Color.blue, Rectangle.from(10, 10, 20, 20)))
    over = top.add_subview(SolidView.new(Color.red, Rectangle.from(15, 15, 10, 10)))
    form = top.render
    assert_equal 0x00A000, form[11, 11], 'the outer view'
    assert_equal 0x0000FF, form[30, 30], 'inside it: the outer view is at 10,10 and the inner at 10,10 within it'
    assert_equal 0xFF0000, form[16, 16], 'a later sibling covers earlier ones'
    assert_equal [outer, over], top.subviews
    assert_equal top, inner.top_view
    assert_equal pt(20, 20), inner.origin_in_top
    assert_equal pt(5, 5), inner.to_local(pt(25, 25))
  end

  def test_borders_backgrounds_and_colours
    view = View.new(nil, Rectangle.from(0, 0, 10, 10))
    view.background = Color.yellow
    view.foreground = Color.red
    view.border_width = 1
    form = view.render
    assert_equal 0xFF0000, form[0, 0]
    assert_equal 0xFF0000, form[9, 5]
    assert_equal 0xFFFF00, form[5, 5]
    assert_equal 'a View(0@0 corner: 10@10)', view.to_s
  end

  def test_view_at_finds_the_deepest_view_and_the_local_point
    top = window(pt(100, 100))
    a = top.add_subview(SolidView.new(Color.red, Rectangle.from(10, 10, 50, 50)))
    b = a.add_subview(SolidView.new(Color.blue, Rectangle.from(5, 5, 20, 20)))
    c = top.add_subview(SolidView.new(Color.green, Rectangle.from(40, 40, 30, 30)))
    assert_equal [top, pt(1, 1)], top.view_at(pt(1, 1))
    assert_equal [a, pt(2, 40)], top.view_at(pt(12, 50))
    assert_equal [b, pt(0, 0)], top.view_at(pt(15, 15)), 'a subview of a subview'
    assert_equal [c, pt(0, 0)], top.view_at(pt(40, 40)), 'where two overlap the later one wins'
    assert_equal [c, pt(29, 29)], top.view_at(pt(69, 69))
    assert_equal [top, pt(99, 99)], top.view_at(pt(99, 99))
    top.remove_subview(c)
    assert_equal [a, pt(30, 30)], top.view_at(pt(40, 40))
    assert_nil c.superview
  end

  def test_release_stops_depending_on_the_model
    model = Model.new
    top = window(pt(50, 50), model)
    inner = top.add_subview(View.new(model, Rectangle.from(0, 0, 10, 10)))
    assert_equal 2, model.dependents.size
    top.release
    assert_empty model.dependents
    assert_same top, inner.superview, 'release only stops the dependencies; the tree is left as it was'
  end

  # --- Controllers and the manager ---------------------------------------------------

  def test_controller_events_arrive_in_the_views_own_coordinates
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(20, 30, 40, 40)))
    recorder = with_recorder(box)
    @manager.open(top)
    @manager.mouse_move(top, 25, 35)
    @manager.mouse_down(top, 25, 35, :red)
    @manager.mouse_up(top, 25, 35, :red)
    assert_equal [:enter, :initialize, [:move, pt(5, 5)], :activity,
                  [:down, pt(5, 5), :red], :activity,
                  [:up, pt(5, 5), :red], :activity], recorder.log
  end

  def test_enter_and_leave_follow_the_pointer_between_views
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    right = with_recorder(top.add_subview(View.new(nil, Rectangle.from(50, 0, 50, 100))))
    @manager.open(top)
    @manager.mouse_move(top, 10, 10)
    @manager.mouse_move(top, 20, 10)
    @manager.mouse_move(top, 60, 10)
    @manager.mouse_move(top, 70, 10)
    @manager.mouse_leave(top)
    assert_equal [:enter, :initialize, [:move, pt(10, 10)], :activity, [:move, pt(20, 10)], :activity,
                  :leave, :terminate], left.log
    assert_equal [:enter, :initialize, [:move, pt(10, 10)], :activity, [:move, pt(20, 10)], :activity,
                  :leave, :terminate], right.log, 'leaving the window counts as leaving the view'
  end

  def test_the_view_that_got_the_button_down_keeps_the_mouse_until_it_is_up
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    right = with_recorder(top.add_subview(View.new(nil, Rectangle.from(50, 0, 50, 100))))
    @manager.open(top)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_move(top, 80, 20) # dragged over the other view
    @manager.mouse_up(top, 90, 30, :red)
    downs = left.log.select { |e| e.is_a?(Array) }
    assert_equal [[:down, pt(10, 10), :red], [:move, pt(80, 20)], [:up, pt(90, 30), :red]], downs,
                 'the dragged-from view gets the moves and the release, in its own coordinates, even outside it'
    assert_empty right.log.select { |e| e.is_a?(Array) }, 'the view dragged over gets none of them'
    @manager.mouse_move(top, 60, 60) # the capture is over
    assert_equal [[:move, pt(10, 60)]], right.log.select { |e| e.is_a?(Array) }
  end

  def test_sensor_tracks_the_mouse_and_buttons
    top = window
    @manager.open(top)
    sensor = @manager.sensor
    refute sensor.any_button_pressed?
    @manager.mouse_down(top, 12, 34, :red)
    assert sensor.red_button_pressed?
    refute sensor.yellow_button_pressed?
    assert_equal pt(12, 34), sensor.cursor_point
    @manager.mouse_down(top, 12, 34, :blue)
    assert sensor.blue_button_pressed?
    @manager.mouse_up(top, 12, 34, :red)
    refute sensor.red_button_pressed?
    assert sensor.any_button_pressed?
    @manager.mouse_up(top, 12, 34, :blue)
    refute sensor.any_button_pressed?
    @manager.key(top, 'q')
    assert_equal 'q', sensor.last_key
    assert_raises(ArgumentError) { sensor.press(:green) }
  end

  def test_sensor_is_available_to_controllers_for_polling_style_code
    seen = []
    controller = Class.new(Controller) do
      define_method(:mouse_move) { |_point| seen << sensor.red_button_pressed? }
    end
    top = window
    top.controller = controller.new
    top.controller.view = top
    @manager.open(top)
    ControlManager.stub(:instance, @manager) do
      @manager.mouse_move(top, 5, 5)
      @manager.mouse_down(top, 5, 5, :red)
      @manager.mouse_move(top, 6, 6)
    end
    assert_equal [false, true], seen
  end

  def test_keys_go_to_the_controller_under_the_pointer
    top = window(pt(100, 100))
    left = with_recorder(top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100))))
    top_recorder = with_recorder(top)
    @manager.open(top)
    @manager.key(top, 'a', 'a') # pointer not over anything yet: the window's controller
    @manager.mouse_move(top, 10, 10)
    @manager.key(top, 'b', 'b')
    @manager.key(top, '', 'Left')
    assert_equal [[:key, 'a', 'a']], top_recorder.log.select { |e| e.is_a?(Array) && e.first == :key }
    assert_equal [[:key, 'b', 'b'], [:key, '', 'Left']], left.log.select { |e| e.is_a?(Array) && e.first == :key }
  end

  def test_control_wanted_means_the_pointer_is_in_the_view
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(20, 20, 30, 30)))
    controller = with_recorder(box)
    @manager.open(top)
    ControlManager.stub(:instance, @manager) do
      @manager.mouse_move(top, 25, 25)
      assert controller.control_wanted?
      @manager.mouse_move(top, 80, 80)
      refute controller.control_wanted?
    end
  end

  def test_errors_in_a_controller_are_reported_not_raised
    top = window
    boom = Class.new(Controller) do
      def mouse_down(_point, _button)
        raise 'controller trouble'
      end
    end
    top.controller = boom.new
    top.controller.view = top
    @manager.open(top)
    @manager.mouse_down(top, 5, 5, :red) # must not raise
    assert_match(/Error in the window 'Test'.*controller trouble/m, Transcript.buffer)
    @manager.mouse_up(top, 5, 5, :red)
    @manager.mouse_move(top, 6, 6) # and the window still works
  end

  def test_cursor_names
    top = window(pt(100, 100))
    box = top.add_subview(View.new(nil, Rectangle.from(0, 0, 50, 100)))
    box.cursor = Cursor.crosshair
    @manager.open(top)
    assert_equal 'arrow', @manager.cursor_name(top)
    @manager.mouse_move(top, 10, 10)
    assert_equal 'crosshair', @manager.cursor_name(top)
    @manager.mouse_move(top, 80, 10)
    assert_equal 'arrow', @manager.cursor_name(top)
  end

  # --- Windows and the manager ----------------------------------------------------------

  def test_opening_draws_the_window_and_tells_the_display_hook
    shown = []
    top = window(pt(30, 20))
    top.display_hook = ->(form) { shown << form }
    top.add_subview(SolidView.new(Color.red, Rectangle.from(0, 0, 10, 10)))
    top.open(@manager)
    assert_equal 1, shown.size
    assert_equal [30, 20], [shown.first.width, shown.first.height]
    assert_equal 0xFF0000, shown.first[0, 0]
    assert_same shown.first, top.form
    assert top.open?(@manager)
    assert_equal [top], @manager.windows
    @manager.refresh(top)
    assert_equal 1, shown.size, 'nothing changed, nothing redrawn'
  end

  def test_the_window_redraws_only_when_asked_and_only_what_changed
    model = Model.new
    shown = []
    top = window(pt(30, 20), model)
    top.display_hook = ->(form) { shown << form }
    child = top.add_subview(SolidView.new(Color.red, Rectangle.from(0, 0, 10, 10)))
    top.open(@manager)
    model.changed
    @manager.refresh_all
    assert_equal 2, shown.size
    @manager.refresh_all
    assert_equal 2, shown.size
    child.invalidate
    @manager.refresh_all
    assert_equal 3, shown.size, 'invalidating any subview redraws the window'
  end

  def test_the_opener_hook_puts_windows_on_screen
    opened = []
    @manager.opener = ->(view) { opened << view }
    top = window
    top.open(@manager)
    assert_equal [top], opened
    assert_equal top, top.open(@manager), 'opening twice does not duplicate it'
    assert_equal [top], @manager.windows
  end

  def test_closing_a_window_releases_it
    model = Model.new
    closed = []
    top = window(pt(40, 40), model)
    top.close_hook = -> { closed << :closed }
    top.open(@manager)
    top.close(@manager)
    assert_empty @manager.windows
    assert_empty model.dependents
    assert_equal [:closed], closed
    refute top.open?(@manager)
    top.close(@manager) # closing again is harmless
    assert_equal [:closed], closed
  end

  def test_events_for_a_closed_window_do_no_harm
    top = window
    top.open(@manager)
    top.close(@manager)
    @manager.mouse_down(top, 1, 1, :red)
    @manager.key(top, 'x')
    @manager.mouse_leave(top)
  end

  def test_form_show_opens_a_window_that_follows_the_form
    form = Form.new(40, 30)
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      view = form.show('My picture')
      assert_equal 'My picture', view.label
      assert_equal [40, 30], [view.form.width, view.form.height]
      assert_equal 0xFFFFFF, view.form[5, 5]
      form.fill(Rectangle.from(0, 0, 10, 10), Color.red)
      form.changed(:pixels)
      manager.refresh_all
      assert_equal 0xFF0000, view.form[5, 5], 'changing the Form and telling its dependents redraws the window'
      assert_kind_of FormView, view.subviews.first
    end
  end

  # --- Widgets ----------------------------------------------------------------------------

  def test_string_views_show_fixed_or_computed_text
    model = Struct.new(:n).new(3)
    computed = StringView.new(model, Rectangle.from(0, 0, 80, 12)) { |m| "n=#{m.n}" }
    assert_equal 'n=3', computed.string
    model.n = 4
    assert_equal 'n=4', computed.string
    fixed = StringView.new(nil, Rectangle.from(0, 0, 80, 12), text: 'Hello', scale: 1)
    assert_equal 'Hello', fixed.string
    assert_operator fixed.render.to_ascii.join.count('#'), :>, 10
    assert_equal 0, StringView.new(nil, Rectangle.from(0, 0, 80, 12)).render.to_ascii.join.count('#')
  end

  def button_window(clicks)
    top = window(pt(100, 60))
    button = top.add_subview(ButtonView.new('Go', Rectangle.from(10, 10, 60, 30)) { clicks << :clicked })
    top.open(@manager)
    [top, button]
  end

  def test_a_button_acts_when_released_inside
    clicks = []
    top, button = button_window(clicks)
    @manager.mouse_down(top, 20, 20, :red)
    assert button.pressed
    assert_empty clicks, 'not yet: only on release'
    @manager.mouse_up(top, 22, 22, :red)
    refute button.pressed
    assert_equal [:clicked], clicks
  end

  def test_a_button_released_outside_does_nothing_and_re_arms_when_dragged_back
    clicks = []
    top, button = button_window(clicks)
    @manager.mouse_down(top, 20, 20, :red)
    @manager.mouse_move(top, 90, 55)
    refute button.pressed, 'dragged off: it pops up'
    @manager.mouse_move(top, 25, 25)
    assert button.pressed, 'dragged back on: pressed again'
    @manager.mouse_move(top, 95, 55)
    @manager.mouse_up(top, 95, 55, :red)
    assert_empty clicks
    refute button.pressed
    @manager.mouse_down(top, 20, 20, :yellow) # other buttons do not press it
    refute button.pressed
    @manager.mouse_up(top, 20, 20, :yellow)
    assert_empty clicks
  end

  def test_a_pressed_button_looks_inverted
    top, button = button_window([])
    normal = top.form.copy(Rectangle.from(10, 10, 60, 30))
    @manager.mouse_down(top, 20, 20, :red)
    assert button.pressed
    pressed = top.form.copy(Rectangle.from(10, 10, 60, 30))
    refute_equal normal, pressed
    assert_equal 0xFFFFFF, normal[3, 3], 'the inside of a button is the background'
    assert_equal 0x000000, pressed[3, 3], 'and it inverts while pressed'
    assert_equal 0x000000, pressed[0, 0], 'the border is drawn on top and stays'
  end

  def test_list_views_select_rows_and_tell_their_block
    chosen = []
    list = ListView.new(%w[red green blue], Rectangle.from(0, 0, 80, 60)) { |index, item| chosen << [index, item] }
    top = window(pt(100, 80))
    top.add_subview(list, Rectangle.from(10, 10, 80, 60))
    top.open(@manager)
    @manager.mouse_down(top, 20, 10 + 2 + 12 + 3, :red) # second row
    assert_equal [[1, 'green']], chosen
    assert_equal 1, list.selection
    assert_equal 'green', list.selected_item
    @manager.mouse_down(top, 20, 10 + 50, :red) # below the last row
    assert_equal [[1, 'green']], chosen, 'a click on empty space selects nothing new'
    @manager.mouse_down(top, 20, 12, :yellow)
    assert_equal 1, list.selection, 'only the red button selects'
    list.items = %w[a b]
    assert_nil list.selection
    assert_equal %w[a b], list.items
    list.selection = 5
    assert_nil list.selection, 'out of range selects nothing'
    list.selection = 0
    assert_equal 'a', list.selected_item
  end

  def test_the_selected_row_is_drawn_inverted
    list = ListView.new(%w[one two], Rectangle.from(0, 0, 60, 40))
    plain = list.render.to_ascii.join.count('#')
    list.selection = 0
    selected = list.render
    refute_equal plain, selected.to_ascii.join.count('#')
    assert_equal 0, selected[3, 3], 'the selection bar is solid foreground'
  end

  # --- The example programs ---------------------------------------------------------------

  def test_counter_example_counts_through_its_buttons
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      window = GraphicsExamples::Counter.open
      model = window.subviews.first.model
      click = ->(x, y) { manager.mouse_down(window, x, y, :red); manager.mouse_up(window, x, y, :red) }
      click.call(200, 70)
      click.call(200, 70)
      click.call(200, 70)
      click.call(30, 70)
      assert_equal 2, model.count
      click.call(120, 70)
      assert_equal 0, model.count
      refute_nil window.form
      assert_operator window.form.copy(Rectangle.from(10, 10, 220, 24)).to_ascii.join.count('#'), :>, 10
      before = window.form.dup
      click.call(200, 70)
      refute_equal before, window.form, 'the picture changed with the model'
    end
  end

  def test_sketch_example_draws_erases_clears_and_takes_keys
    manager = ControlManager.new
    ControlManager.stub(:instance, manager) do
      window = GraphicsExamples::Sketch.open(100, 80)
      model = window.subviews.first.model
      manager.mouse_down(window, 10, 10, :red)
      manager.mouse_move(window, 40, 10)
      manager.mouse_up(window, 40, 10, :red)
      assert_equal 0, model.form[25, 10], 'drawn in black while dragging'
      assert_equal 0, window.form[25, 10], 'and visible in the window'
      manager.mouse_move(window, 60, 60) # no button: no drawing
      assert_equal 0xFFFFFF, model.form[60, 60]

      manager.mouse_move(window, 10, 10)
      manager.key(window, 'r')
      manager.key(window, '5')
      assert_equal [Color.red, 5], [model.color, model.width]
      manager.mouse_down(window, 10, 40, :red)
      manager.mouse_up(window, 10, 40, :red)
      assert_equal 0xFF0000, model.form[10, 40]

      manager.mouse_move(window, 25, 10)
      manager.mouse_down(window, 25, 10, :yellow) # erase
      manager.mouse_up(window, 25, 10, :yellow)
      assert_equal 0xFFFFFF, model.form[25, 10]

      manager.key(window, 'c')
      assert_equal 0, model.form.to_ascii(ink_color: Color.red).join.count('#')
      manager.mouse_down(window, 10, 10, :red)
      manager.mouse_up(window, 10, 10, :red)
      manager.mouse_down(window, 10, 10, :blue) # blue clears
      manager.mouse_up(window, 10, 10, :blue)
      assert_equal 0xFFFFFF, model.form[10, 10]
      manager.key(window, 'k')
      assert_equal Color.black, model.color
      manager.key(window, 'z') # ignored
      manager.key(window, '0') # not a width
      assert_equal 5, model.width
    end
  end
end
