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

  # --- Scrolling lists ----------------------------------------------------------------------

  def numbers(count)
    Array.new(count) { |i| "item #{i}" }
  end

  def scrolling_window(count = 30, chosen = [])
    top = window(pt(100, 64))
    list = ListView.new(numbers(count), Rectangle.from(0, 0, 100, 64)) { |index, item| chosen << [index, item] }
    top.add_subview(list)
    top.open(@manager)
    [top, list]
  end

  def test_a_list_shows_only_the_rows_that_fit_and_scrolls
    top, list = scrolling_window
    assert_equal 5, list.visible_rows, '64 pixels high: (64 - 4) / 12'
    assert_equal 0, list.top
    first_page = top.form.to_ascii.join
    list.scroll_by(3)
    assert_equal 3, list.top
    @manager.refresh(top)
    refute_equal first_page, top.form.to_ascii.join, 'the picture scrolled'
    list.scroll_by(1000)
    assert_equal 25, list.top, 'stops when the last row is at the bottom'
    list.scroll_by(-1000)
    assert_equal 0, list.top
    assert_equal 30, list.scroll_total
  end

  def test_the_scroll_bar_appears_only_when_needed
    _top, long = scrolling_window(30)
    _top2, short = scrolling_window(3)
    assert long.scrollbar_visible?
    refute short.scrollbar_visible?
    bar = long.scrollbar_rect
    assert_operator long.render[bar.left + 2, bar.top + 2], :!=, 0xFFFFFF, 'something is drawn there'
    assert_equal 0xFFFFFF, short.render[short.width - 4, 4], 'but not for a short list'
  end

  def test_the_thumb_reflects_the_scroll_position
    _top, list = scrolling_window(30)
    start = list.thumb_rect
    assert_equal list.scrollbar_rect.top, start.top, 'at the top'
    assert_in_delta list.scrollbar_rect.height * 5 / 30.0, start.height, 2
    list.scroll_by(1000)
    finish = list.thumb_rect
    assert_equal list.scrollbar_rect.bottom, finish.bottom, 'at the bottom'
    list.scroll_by(-1000)
    list.scroll_to_point(pt(95, 1000))
    assert_equal 25, list.top, 'dragging the thumb to the bottom'
    list.scroll_to_point(pt(95, -50))
    assert_equal 0, list.top
    list.scroll_to_point(pt(95, list.scrollbar_rect.center.y))
    assert_in_delta 12, list.top, 2, 'the middle'
  end

  def test_clicking_and_dragging_the_scroll_bar
    top, list = scrolling_window(30)
    chosen = []
    list.on_select = ->(index, _item) { chosen << index }
    @manager.mouse_down(top, 95, 60, :red)
    assert_operator list.top, :>, 15, 'a press low on the bar scrolls there'
    assert_empty chosen, 'and does not select a row'
    @manager.mouse_move(top, 95, 5)
    assert_equal 0, list.top, 'dragging follows the pointer'
    @manager.mouse_move(top, 20, 30) # off the bar, still dragging: still scrolls (to the middle)
    middle = list.top
    assert_in_delta 12, middle, 2
    @manager.mouse_up(top, 20, 30, :red)
    @manager.mouse_move(top, 95, 60) # no longer dragging: the list stays where it was
    assert_equal middle, list.top
  end

  def test_the_wheel_scrolls_the_list_under_the_pointer
    top, list = scrolling_window
    @manager.mouse_wheel(top, 20, 20, 3)
    assert_equal 3, list.top
    @manager.mouse_wheel(top, 20, 20, -1)
    assert_equal 2, list.top
    @manager.mouse_wheel(top, 20, 20, -50)
    assert_equal 0, list.top
    other = window(pt(50, 50))
    other.open(@manager)
    @manager.mouse_wheel(other, 5, 5, 3) # a view with no use for it: nothing happens, no error
  end

  def test_clicking_a_row_of_a_scrolled_list_selects_that_row
    chosen = []
    top, list = scrolling_window(30, chosen)
    list.scroll_by(10)
    @manager.mouse_down(top, 20, 2 + 6, :red)
    @manager.mouse_up(top, 20, 8, :red)
    assert_equal [[10, 'item 10']], chosen
    @manager.mouse_down(top, 20, 2 + (12 * 2) + 3, :red)
    assert_equal [10, 12], chosen.map(&:first)
    assert_equal 12, list.selection
    @manager.mouse_down(top, 20, 1, :red) # above the first row: nothing
    assert_equal 2, chosen.size
  end

  def test_keys_move_the_selection_and_scroll_to_keep_it_visible
    chosen = []
    top, list = scrolling_window(30, chosen)
    @manager.mouse_down(top, 20, 8, :red) # clicking the list gives it the keyboard
    @manager.mouse_up(top, 20, 8, :red)
    assert_equal 0, list.selection
    @manager.mouse_move(top, 95, 5) # the pointer wanders off the rows: keys still go to the list
    @manager.key(top, '', 'Down')
    @manager.key(top, '', 'Down')
    assert_equal 2, list.selection
    5.times { @manager.key(top, '', 'Down') }
    assert_equal 7, list.selection
    assert_equal 3, list.top, 'scrolled so row 7 is the last one showing (rows 3 to 7)'
    @manager.key(top, '', 'Up')
    assert_equal 6, list.selection
    @manager.key(top, '', 'Next') # page down: 4 rows
    assert_equal 10, list.selection
    @manager.key(top, '', 'Prior')
    assert_equal 6, list.selection
    @manager.key(top, '', 'End')
    assert_equal 29, list.selection
    assert_equal 25, list.top
    @manager.key(top, '', 'Home')
    assert_equal 0, list.selection
    assert_equal 0, list.top
    @manager.key(top, '', 'Up')
    assert_equal 0, list.selection, 'stops at the first row'
    assert_equal chosen.last, [0, 'item 0']
    assert_equal list, @manager.focus_controller(top).view
  end

  def test_the_first_down_arrow_selects_the_first_row
    top, list = scrolling_window
    @manager.mouse_down(top, 95, 5, :red) # on the scroll bar: focus, but no row selected
    @manager.mouse_up(top, 95, 5, :red)
    assert_nil list.selection
    @manager.key(top, '', 'Down')
    assert_equal 0, list.selection
  end

  def test_setting_the_selection_in_code_scrolls_to_it
    _top, list = scrolling_window
    list.selection = 20
    assert_equal 16, list.top
    list.selection = 2
    assert_equal 2, list.top
    list.items = numbers(3)
    assert_nil list.selection
    assert_equal 0, list.top, 'a shorter list cannot stay scrolled'
    assert_empty ListView.new([], Rectangle.from(0, 0, 50, 50)).tap(&:select_first).items
  end

  # --- Pop-up menus ---------------------------------------------------------------------------

  # A window whose one big view has a yellow-button menu; +chosen+ collects what was picked.
  def menu_window(chosen = [], extent: pt(200, 150))
    top = window(extent)
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, extent.x, extent.y)))
    log = []
    controller = Class.new(MouseMenuController) do
      define_method(:mouse_down) { |point, button| log << [:down, point, button] }
      define_method(:mouse_up) { |point, button| log << [:up, point, button] }
      define_method(:mouse_move) { |point| log << [:move, point] }
    end.new(area)
    area.controller = controller
    controller.yellow_button_menu = PopUpMenu.new(['Alpha', '-', ['Beta', -> { chosen << :beta_action }], 'Gamma']) do |index, label|
      chosen << [index, label]
    end
    top.open(@manager)
    [top, controller, log]
  end

  def test_popup_menu_layout_and_labels
    menu = PopUpMenu.new(['Alpha', '-', 'Beta'])
    assert_equal %w[Alpha - Beta], menu.labels
    assert menu.separator?(1)
    refute menu.separator?(0)
    assert_equal 2 + 12 + 6 + 12 + 2, menu.height, 'two rows and a short separator, with margins'
    assert_operator menu.width, :>=, Font.default.width_of('Alpha') + 16
    assert_equal 40, PopUpMenu.new(['a']).width, 'a minimum width'
    assert_equal %w[again undo copy], PopUpMenu.labels("again\nundo\ncopy").labels
    assert_empty PopUpMenu.new.labels
  end

  def test_popup_menu_items_by_position_and_highlighting
    top = window(pt(200, 150))
    menu = PopUpMenu.new(['Alpha', '-', 'Beta'])
    menu.place_in(top, pt(50, 40))
    assert_equal pt(46, 36), menu.bounds.origin, 'the pointer lands inside the first item'
    assert_equal 0, menu.item_at(pt(50, 40))
    assert_nil menu.item_at(pt(50, 36 + 2 + 12 + 2)), 'a separator is not an item'
    assert_equal 2, menu.item_at(pt(50, 36 + 2 + 12 + 6 + 3))
    assert_nil menu.item_at(pt(5, 5)), 'outside'
    assert_nil menu.highlight
    menu.track(pt(50, 40))
    assert_equal 0, menu.highlight
    menu.track(pt(5, 5))
    assert_nil menu.highlight
  end

  def test_popup_menus_stay_inside_the_window
    top = window(pt(100, 60))
    menu = PopUpMenu.new(%w[one two three four])
    menu.place_in(top, pt(95, 55))
    assert_operator menu.bounds.right, :<=, 100
    assert_operator menu.bounds.bottom, :<=, 60
    menu.place_in(top, pt(-20, -20))
    assert_equal pt(0, 0), menu.bounds.origin
    tiny = window(pt(20, 20))
    menu.place_in(tiny, pt(5, 5)) # bigger than the window: top-left corner, no error
    assert_equal pt(0, 0), menu.bounds.origin
  end

  def test_highlight_moves_over_items_skipping_separators_and_wraps
    menu = PopUpMenu.new(['a', '-', 'b', 'c'])
    menu.move_highlight(1)
    assert_equal 0, menu.highlight
    menu.move_highlight(1)
    assert_equal 2, menu.highlight, 'the separator is skipped'
    menu.move_highlight(1)
    menu.move_highlight(1)
    assert_equal 0, menu.highlight, 'wraps round'
    menu.move_highlight(-1)
    assert_equal 3, menu.highlight
    fresh = PopUpMenu.new(%w[x y z])
    fresh.move_highlight(-1)
    assert_equal 2, fresh.highlight, 'up from nothing starts at the last'
    PopUpMenu.new.move_highlight(1) # an empty menu: no error
  end

  def test_choosing_runs_the_items_action_then_the_block
    log = []
    menu = PopUpMenu.new([['One', -> { log << :one }], 'Two', '-']) { |index, label| log << [index, label] }
    menu.choose(0)
    menu.choose(1)
    menu.choose(2) # a separator
    menu.choose(9) # no such item
    assert_equal [:one, [0, 'One'], [1, 'Two']], log
    menu.on_select = ->(_i, _l) { log << :replaced }
    menu.choose(1)
    assert_equal :replaced, log.last
  end

  def test_press_drag_and_release_chooses_the_item_under_the_pointer
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    assert_kind_of PopUpMenu, top.popup, 'the menu is showing'
    assert_empty log, 'the press went to the menu, not the controller'
    assert_equal 0, top.popup.highlight, 'the first item is under the pointer'
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4) # down onto Beta
    assert_equal 2, top.popup.highlight
    @manager.mouse_up(top, 100, 60 + 2 + 12 + 6 + 4, :yellow)
    assert_nil top.popup, 'the menu goes away'
    assert_equal [:beta_action, [2, 'Beta']], chosen
    assert_empty log, 'the controller saw none of it'
    refute @manager.sensor.any_button_pressed?
  end

  def test_release_off_the_menu_after_dragging_cancels
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_move(top, 190, 140)
    @manager.mouse_up(top, 190, 140, :yellow)
    assert_nil top.popup
    assert_empty chosen
    assert_empty log
  end

  def test_release_without_moving_leaves_a_click_menu_open
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    refute_nil top.popup, 'a click menu: it stays'
    assert_empty chosen
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4)
    assert_equal 2, top.popup.highlight
    @manager.mouse_down(top, 100, 60 + 2 + 12 + 6 + 4, :red) # any button chooses
    assert_nil top.popup
    assert_equal [:beta_action, [2, 'Beta']], chosen
    @manager.mouse_up(top, 100, 60 + 2 + 12 + 6 + 4, :red)
    assert_empty log, 'the release that finished the choice does not leak to the controller'
    @manager.mouse_move(top, 10, 10)
    assert_equal [[:move, pt(10, 10)]], log, 'afterwards the controller works as normal'
  end

  def test_clicking_outside_a_click_menu_dismisses_it
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_down(top, 10, 140, :red)
    @manager.mouse_up(top, 10, 140, :red)
    assert_nil top.popup
    assert_empty chosen
    assert_empty log, 'the dismissing click is not delivered'
  end

  def test_keys_drive_an_open_menu_and_do_not_reach_controllers
    chosen = []
    top, controller, = menu_window(chosen)
    keys = []
    controller.define_singleton_method(:key_pressed) { |char, keysym| keys << [char, keysym] }
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.key(top, '', 'Down')
    assert_equal 2, top.popup.highlight, 'from Alpha down, skipping the separator'
    @manager.key(top, 'x', 'x')
    @manager.key(top, '', 'Return')
    assert_nil top.popup
    assert_equal [:beta_action, [2, 'Beta']], chosen
    assert_empty keys

    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.key(top, '', 'Escape')
    assert_nil top.popup, 'Escape dismisses'
    assert_equal 2, chosen.size, 'Escape chose nothing more (the first choice recorded its action and its label)'
    @manager.key(top, 'q', 'q')
    assert_equal [['q', 'q']], keys, 'with the menu gone keys flow again'
  end

  def test_return_with_nothing_highlighted_dismisses
    top, = menu_window
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_move(top, 5, 5) # off the menu: nothing highlighted
    @manager.key(top, '', 'Return')
    assert_nil top.popup
  end

  def test_other_buttons_use_the_controller_normally
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :red)
    @manager.mouse_up(top, 100, 60, :red)
    assert_nil top.popup, 'only the yellow button has a menu'
    assert_equal [[:down, pt(100, 60), :red], [:up, pt(100, 60), :red]], log
  end

  def test_the_wheel_and_command_keys_are_ignored_while_a_menu_is_open
    top, controller, = menu_window
    wheeled = []
    controller.define_singleton_method(:mouse_wheel) { |_point, lines| wheeled << lines }
    controller.define_singleton_method(:command_key) { |_keysym| true }
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_wheel(top, 100, 60, 3)
    assert_empty wheeled
    assert_equal false, @manager.command_key(top, 'c')
  end

  def test_the_menu_is_drawn_over_the_window_and_removed_when_dismissed
    top, = menu_window
    before = top.form.to_ascii.join
    @manager.mouse_down(top, 100, 60, :yellow)
    during = top.form
    refute_equal before, during.to_ascii.join, 'the menu is in the window picture'
    menu = top.popup
    assert_equal 0x000000, during[menu.bounds.left, menu.bounds.top], 'with a border'
    assert_equal 0x000000, during[menu.bounds.left + 3, menu.bounds.top + 4], 'the highlighted first row is solid'
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4)
    refute_equal during, top.form, 'the highlight moved'
    @manager.key(top, '', 'Escape')
    assert_equal before, top.form.to_ascii.join, 'and it is gone again'
  end

  def test_a_menu_action_that_fails_is_reported_and_the_menu_still_closes
    top = window(pt(100, 100))
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, 100, 100)))
    controller = MouseMenuController.new(area)
    controller.yellow_button_menu = PopUpMenu.new([['Boom', -> { raise 'menu trouble' }]])
    area.controller = controller
    top.open(@manager)
    @manager.mouse_down(top, 50, 50, :yellow)
    @manager.mouse_up(top, 50, 70, :yellow) # moved: choose what is under the pointer
    @manager.mouse_up(top, 50, 50, :yellow) # stray extra release: harmless
    assert_nil top.popup
    @manager.mouse_move(top, 10, 10)
    @manager.mouse_down(top, 50, 50, :yellow)
    @manager.mouse_move(top, 50, 54)
    @manager.mouse_up(top, 50, 54, :yellow)
    assert_match(/Error in the window 'Test'.*menu trouble/m, Transcript.buffer)
    assert_nil top.popup
  end

  def test_choosing_can_open_another_menu
    top = window(pt(200, 100))
    second = PopUpMenu.new(%w[inner])
    first = PopUpMenu.new([['outer', -> { @manager.show_popup(top, second, pt(100, 50)) }]])
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, 200, 100)))
    controller = MouseMenuController.new(area)
    controller.blue_button_menu = first
    area.controller = controller
    top.open(@manager)
    @manager.mouse_down(top, 30, 30, :blue)
    @manager.mouse_up(top, 30, 36, :blue)
    assert_same second, top.popup, 'the choice showed the next menu'
  end

  def test_menus_can_be_shown_from_code
    chosen = []
    top = window(pt(200, 120))
    top.open(@manager)
    menu = PopUpMenu.new(%w[first second]) { |i, label| chosen << [i, label] }
    ControlManager.stub(:instance, @manager) { menu.pop_up(top, pt(20, 20)) }
    assert_same menu, top.popup
    assert_equal 0, top.popup.highlight, 'the pointer is over the first item'
    @manager.key(top, '', 'Down')
    @manager.key(top, '', 'Return')
    assert_equal [[1, 'second']], chosen
    @manager.sensor.move_to(pt(40, 40))
    ControlManager.stub(:instance, @manager) { menu.pop_up(top) } # at the pointer
    assert_equal pt(36, 36), top.popup.bounds.origin
  end

  def test_closing_a_window_drops_its_menu_state
    top, = menu_window
    @manager.mouse_down(top, 100, 60, :yellow)
    top.close(@manager)
    @manager.mouse_up(top, 100, 60, :yellow) # no window, no menu: nothing to do
    @manager.key(top, '', 'Return')
  end

  def test_lists_can_have_menus_too
    chosen = []
    top = window(pt(200, 100))
    list = top.add_subview(ListView.new(%w[a b c], Rectangle.from(0, 0, 100, 100)))
    list.controller.yellow_button_menu = PopUpMenu.new(%w[Open Delete]) { |_i, label| chosen << label }
    top.open(@manager)
    @manager.mouse_down(top, 20, 20, :yellow)
    @manager.mouse_move(top, 20, 20 + 2 + 12 + 3)
    @manager.mouse_up(top, 20, 20 + 2 + 12 + 3, :yellow)
    assert_equal ['Delete'], chosen
    assert_nil list.selection, 'the menu press did not select a row'
  end

  # --- Keyboard focus, modifiers and clicks --------------------------------------------------

  def test_focus_follows_clicks_on_controllers_that_want_it
    top = window(pt(100, 100))
    lists = [ListView.new(%w[a b], Rectangle.from(0, 0, 50, 100)), ListView.new(%w[c d], Rectangle.from(50, 0, 50, 100))]
    lists.each { |list| top.add_subview(list) }
    button = top.add_subview(ButtonView.new('x', Rectangle.from(0, 80, 20, 20)))
    top.open(@manager)
    assert_nil @manager.focus_controller(top)
    @manager.mouse_down(top, 10, 5, :red)
    @manager.mouse_up(top, 10, 5, :red)
    assert_same lists[0].controller, @manager.focus_controller(top)
    @manager.mouse_down(top, 60, 5, :red)
    @manager.mouse_up(top, 60, 5, :red)
    assert_same lists[1].controller, @manager.focus_controller(top)
    @manager.mouse_down(top, 5, 85, :red) # a button does not want the keyboard: focus stays
    @manager.mouse_up(top, 5, 85, :red)
    assert_same lists[1].controller, @manager.focus_controller(top)
    refute button.controller.wants_keyboard_focus?
    @manager.mouse_move(top, 10, 50)
    @manager.key(top, '', 'Down') # goes to the focused list, not the one under the pointer
    assert_equal 1, lists[1].selection, 'the click selected row 0, so Down moves to row 1'
    assert_equal 0, lists[0].selection, 'the other list kept its own selection (from the earlier click)'
    top.close(@manager)
    assert_nil @manager.focus_controller(top)
  end

  def test_focus_gained_and_lost_are_announced
    log = []
    top = window(pt(100, 50))
    listener = lambda do |name|
      Class.new(ListController) do
        define_method(:focus_gained) { log << [name, :gained] }
        define_method(:focus_lost) { log << [name, :lost] }
      end
    end
    a = top.add_subview(ListView.new(%w[a], Rectangle.from(0, 0, 50, 50)))
    b = top.add_subview(ListView.new(%w[b], Rectangle.from(50, 0, 50, 50)))
    a.controller = listener.call(:a).new(a)
    b.controller = listener.call(:b).new(b)
    top.open(@manager)
    @manager.mouse_down(top, 10, 5, :red)
    @manager.mouse_up(top, 10, 5, :red)
    @manager.mouse_down(top, 10, 5, :red) # same one again: no new announcement
    @manager.mouse_up(top, 10, 5, :red)
    @manager.mouse_down(top, 60, 5, :red)
    assert_equal [[:a, :gained], [:a, :lost], [:b, :gained]], log
  end

  def test_modifier_keys_reach_the_sensor
    seen = []
    controller = Class.new(Controller) do
      define_method(:key_pressed) { |_char, keysym| seen << [keysym, sensor.shift_pressed?, sensor.control_pressed?] }
    end
    top = window
    top.controller = controller.new(top)
    top.open(@manager)
    ControlManager.stub(:instance, @manager) do
      @manager.key(top, '', 'Left', 0)
      @manager.key(top, '', 'Left', InputSensor::SHIFT)
      @manager.key(top, '', 'Left', InputSensor::SHIFT | InputSensor::CONTROL)
    end
    assert_equal [['Left', false, false], ['Left', true, false], ['Left', true, true]], seen
    @manager.mouse_down(top, 1, 1, :red, InputSensor::SHIFT)
    assert @manager.sensor.shift_pressed?, 'mouse events carry the modifiers too'
  end

  def test_double_and_triple_clicks_are_counted
    now = 100.0
    @manager.clock = -> { now }
    top = window
    top.open(@manager)
    counts = lambda do |x, y, button = :red|
      @manager.mouse_down(top, x, y, button)
      @manager.mouse_up(top, x, y, button)
      @manager.sensor.click_count
    end
    assert_equal 1, counts.call(10, 10)
    now += 0.2
    assert_equal 2, counts.call(11, 10), 'quickly, nearly the same place'
    now += 0.2
    assert_equal 3, counts.call(10, 11)
    now += 0.2
    assert_equal 3, counts.call(10, 10), 'it stops at 3'
    now += 0.2
    assert_equal 3, counts.call(10, 10)
    now += 1.0
    assert_equal 1, counts.call(10, 10), 'too slow'
    now += 0.1
    assert_equal 1, counts.call(60, 10), 'too far'
    now += 0.1
    assert_equal 1, counts.call(60, 10, :yellow), 'a different button'
  end

  def test_command_keys_go_to_the_focused_controller_and_report_whether_they_were_used
    handled = []
    controller = Class.new(Controller) do
      define_method(:command_key) { |keysym| handled << keysym; keysym == 'c' }
      define_method(:wants_keyboard_focus?) { true }
    end
    top = window
    top.controller = controller.new(top)
    top.open(@manager)
    assert_equal true, @manager.command_key(top, 'c')
    assert_equal false, @manager.command_key(top, 'q')
    assert_equal %w[c q], handled
    assert_equal false, window.controller.command_key('c'), 'the default is "not handled"'
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

# --- Text editing ---------------------------------------------------------------------------------

class TextEditingTest < Minitest::Test
  CELL = TextView::CELL_WIDTH
  ROW = TextView::LINE_HEIGHT

  def setup
    Transcript.clear
    Clipboard.backend = nil
    Clipboard.text = ''
    @manager = ControlManager.new
    @saved_instance = ControlManager.instance_variable_get(:@instance)
    ControlManager.instance_variable_set(:@instance, @manager) # controllers read the shared sensor
  end

  def teardown
    ControlManager.instance_variable_set(:@instance, @saved_instance)
    Clipboard.backend = nil
    Clipboard.text = ''
  end

  def pt(x, y)
    Point.new(x, y)
  end

  def view(text = '', width: 200, height: 60, **options)
    TextView.new(nil, Rectangle.from(0, 0, width, height), text: text, **options)
  end

  # The point in a text view where character +column+ of row +row+ starts.
  def cell(column, row = 0)
    pt(TextView::MARGIN_X + (column * CELL), TextView::MARGIN_Y + (row * ROW) + 2)
  end

  def text_window(text = '', extent: pt(200, 60), **options)
    top = StandardSystemView.new('Text', nil, extent)
    field = top.add_subview(TextView.new(nil, Rectangle.new(pt(0, 0), extent), text: text, **options))
    top.open(@manager)
    [top, field]
  end

  def type(top, string)
    string.each_char do |char|
      char == "\n" ? @manager.key(top, "\r", 'Return') : @manager.key(top, char, char)
    end
  end

  # --- the editing methods --------------------------------------------------------------

  def test_typing_inserts_at_the_caret
    v = view
    v.insert('a')
    v.insert('b')
    assert_equal 'ab', v.text
    assert_equal [2, 2], [v.caret, v.anchor]
    v.place_caret(1)
    v.insert('X')
    assert_equal 'aXb', v.text
    assert_equal 2, v.caret
  end

  def test_typing_replaces_the_selection
    v = view('hello world')
    v.select_word_at(7)
    assert_equal 'world', v.selected_text
    v.insert('there')
    assert_equal 'hello there', v.text
    assert_equal 11, v.caret
    assert_nil v.selection_range
  end

  def test_backspace_and_delete
    v = view('abcd')
    v.place_caret(2)
    v.delete_backward
    assert_equal ['acd', 1], [v.text, v.caret]
    v.delete_forward
    assert_equal 'ad', v.text
    v.place_caret(0)
    v.delete_backward
    assert_equal 'ad', v.text, 'nothing before the start'
    v.place_caret(2)
    v.delete_forward
    assert_equal 'ad', v.text, 'nothing after the end'
    v.select_all
    v.delete_forward
    assert_equal '', v.text, 'with a selection either key deletes it'
    v.insert('x')
    v.select_all
    v.delete_backward
    assert_equal '', v.text
  end

  def test_line_endings_and_tabs_are_normalised
    v = view
    v.insert("a\r\nb\rc\td")
    assert_equal "a\nb\nc  d", v.text
    v.text = "x\ty"
    assert_equal 'x  y', v.text
    v.tab_width = 4
    v.insert("\t")
    assert v.text.start_with?('    '), 'four spaces, at the caret (the start)'
  end

  def test_a_one_line_view_turns_newlines_into_spaces
    v = view('', multiline: false)
    v.insert("a\nb")
    assert_equal 'a b', v.text
    v.text = "one\ntwo"
    assert_equal 'one two', v.text
    assert_equal 1, v.line_count
  end

  def test_movement_by_character_line_and_text
    v = view("abc\ndef\nghi")
    v.place_caret(0)
    v.move(:right)
    assert_equal 1, v.caret
    v.move(:down)
    assert_equal 5, v.caret, 'one down: same column'
    v.move(:down)
    assert_equal 9, v.caret
    v.move(:down)
    assert_equal 11, v.caret, 'down from the last line goes to the end'
    v.move(:up)
    assert_equal 5, v.caret, 'and up remembers the column you were in'
    v.move(:home)
    assert_equal 4, v.caret
    v.move(:end)
    assert_equal 7, v.caret
    v.move(:text_start)
    assert_equal 0, v.caret
    v.move(:left)
    assert_equal 0, v.caret, 'stops at the start'
    v.move(:text_end)
    assert_equal 11, v.caret
    v.move(:right)
    assert_equal 11, v.caret
    v.move(:up)
    v.move(:up)
    v.move(:up)
    assert_equal 0, v.caret, 'up from the first line goes to the start'
  end

  def test_the_column_is_remembered_through_a_short_line
    v = view("long line\nx\nlong line")
    v.place_caret(6)
    v.move(:down)
    assert_equal 11, v.caret, 'the short line: its end'
    v.move(:down)
    assert_equal 12 + 6, v.caret, 'and back to column 6 on the next'
    v.move(:left)
    v.move(:up)
    assert_equal 11, v.caret, 'moving sideways forgets the remembered column'
  end

  def test_movement_by_word
    v = view('foo bar  baz')
    v.move(:word_right)
    assert_equal 3, v.caret
    v.move(:word_right)
    assert_equal 7, v.caret
    v.move(:word_right)
    assert_equal 12, v.caret
    v.move(:word_left)
    assert_equal 9, v.caret
    v.move(:word_left)
    assert_equal 4, v.caret
  end

  def test_extending_the_selection_and_collapsing_it
    v = view('abcdef')
    v.place_caret(2)
    v.move(:right, extend: true)
    v.move(:right, extend: true)
    assert_equal [2, 4], v.selection_range
    assert_equal 'cd', v.selected_text
    v.move(:left, extend: true)
    assert_equal [2, 3], v.selection_range
    v.move(:left)
    assert_equal [2, 2], [v.caret, v.anchor], 'plain left collapses to the start of the selection'
    v.select_all
    v.move(:right)
    assert_equal 6, v.caret
    assert_nil v.selection_range
    assert_raises(ArgumentError) { v.move(:sideways) }
  end

  def test_selecting_words_lines_and_everything
    v = view("one two\nthree")
    v.select_word_at(5)
    assert_equal 'two', v.selected_text
    v.select_word_at(3)
    assert_equal 'one', v.selected_text, 'just after a word selects that word'
    v.select_line_at(10)
    assert_equal 'three', v.selected_text
    v.select_line_at(2)
    assert_equal 'one two', v.selected_text, 'a line without its newline'
    v.select_all
    assert_equal "one two\nthree", v.selected_text
    spaced = view('a  b')
    spaced.select_word_at(2)
    assert_equal ' ', spaced.selected_text, 'between words: the one character'
    empty = view
    empty.select_word_at(0)
    empty.select_line_at(0)
    assert_equal '', empty.selected_text
  end

  def test_points_map_to_character_offsets
    v = view("hello\nworld\n\nlast")
    assert_equal 0, v.index_at(pt(0, 0))
    assert_equal 2, v.index_at(cell(2))
    assert_equal 3, v.index_at(pt(TextView::MARGIN_X + (2 * CELL) + 4, TextView::MARGIN_Y)), 'nearer the next boundary'
    assert_equal 6 + 4, v.index_at(cell(4, 1))
    assert_equal 5, v.index_at(cell(40, 0)), 'past the end of a line: its end'
    assert_equal 12, v.index_at(cell(3, 2)), 'an empty line'
    assert_equal 13 + 4, v.index_at(cell(10, 5)), 'below the text: the last line'
    assert_equal 0, v.index_at(pt(-30, -30))
  end

  def test_line_and_column_helpers
    v = view("ab\ncde\n")
    assert_equal 3, v.line_count
    assert_equal [0, 3, 7], v.line_starts
    assert_equal ['ab', 'cde', ''], v.lines
    assert_equal [1, 2], v.line_and_column(5)
    assert_equal [2, 0], v.line_and_column(7)
    assert_equal [0, 0], v.line_and_column(0)
  end

  # --- undo ------------------------------------------------------------------------------------

  def test_undo_takes_back_runs_of_typing_together
    v = view
    v.insert('a')
    v.insert('b')
    v.insert(' ')
    v.insert('c')
    assert_equal 'ab c', v.text
    assert_equal true, v.undo
    assert_equal 'ab ', v.text
    v.undo
    assert_equal 'ab', v.text
    v.undo
    assert_equal '', v.text
    assert_equal false, v.undo, 'nothing left'
  end

  def test_undo_restores_the_caret_and_deletions
    v = view('hello')
    v.place_caret(5)
    v.delete_backward
    v.delete_backward
    assert_equal 'hel', v.text
    v.undo
    assert_equal ['hell', 4], [v.text, v.caret]
    v.undo
    assert_equal ['hello', 5], [v.text, v.caret]
    v.select_all
    v.insert('X')
    v.undo
    assert_equal 'hello', v.text
  end

  def test_setting_the_text_clears_undo_and_moves_to_the_start
    v = view
    v.insert('abc')
    v.text = 'new'
    assert_equal ['new', 0], [v.text, v.caret]
    assert_equal false, v.undo
  end

  def test_undo_is_bounded
    v = view
    (TextView::UNDO_LIMIT + 20).times { |i| v.insert("#{i} ") }
    steps = 0
    steps += 1 while v.undo
    assert_equal TextView::UNDO_LIMIT, steps
  end

  # --- clipboard ------------------------------------------------------------------------------

  def test_cut_copy_paste
    v = view('hello world')
    v.select_word_at(7)
    v.copy
    assert_equal 'world', Clipboard.text
    assert_equal 'hello world', v.text
    v.select_word_at(1)
    v.cut
    assert_equal ' world', v.text
    assert_equal 'hello', Clipboard.text
    v.place_caret(0)
    v.paste
    assert_equal 'hello world', v.text
    v.select_all
    v.paste
    assert_equal 'hello', v.text, 'paste replaces the selection'
    v.undo
    assert_equal 'hello world', v.text
  end

  def test_copy_with_nothing_selected_and_paste_with_nothing_copied_do_nothing
    v = view('abc')
    Clipboard.text = 'keep'
    v.copy
    assert_equal 'keep', Clipboard.text
    v.cut
    assert_equal 'abc', v.text
    Clipboard.text = ''
    v.paste
    assert_equal 'abc', v.text
  end

  def test_the_clipboard_can_use_another_store
    store = Struct.new(:value) do
      def get = value
      def set(text) = (self.value = text)
    end.new('from outside')
    Clipboard.backend = store
    assert_equal 'from outside', Clipboard.text
    v = view('x')
    v.paste
    assert_equal 'from outsidex', v.text
    v.select_all
    v.copy
    assert_equal 'from outsidex', store.value, 'copying writes to the other store'
    Clipboard.text = nil
    assert_equal '', store.value
  end

  def test_a_read_only_view_selects_and_copies_but_does_not_change
    v = view('read only', editable: false)
    v.insert('x')
    v.select_all
    v.delete_backward
    v.cut
    assert_equal 'read only', v.text
    assert_equal 'read only', Clipboard.text, 'cut copied before refusing to delete'
    assert_equal false, v.undo
  end

  # --- change notification and the model -----------------------------------------------------------

  def test_on_change_hears_every_edit
    heard = []
    v = TextView.new(nil, Rectangle.from(0, 0, 100, 40)) { |text| heard << text }
    v.insert('a')
    v.insert('b')
    v.delete_backward
    v.undo
    assert_equal %w[a ab a ab], heard
  end

  def test_one_line_accept
    got = []
    v = view('hello', multiline: false)
    v.on_accept = ->(text) { got << text }
    v.accept
    assert_equal ['hello'], got
    view('x').accept # no handler: nothing
  end

  class Note < Model
    attr_reader :body

    def initialize
      super
      @body = +'start'
    end

    def body=(text)
      @body = text
      changed(:body)
    end
  end

  def test_the_view_reads_and_writes_a_model_aspect
    note = Note.new
    v = TextView.new(note, Rectangle.from(0, 0, 100, 40), aspect: :body)
    assert_equal 'start', v.text
    assert_equal [v], note.dependents
    v.insert('X')
    assert_equal 'Xstart', note.body, 'typing writes the model'
    assert_equal 1, v.caret, 'and the echo from the model does not reload and move the caret'
    note.body = 'changed elsewhere'
    assert_equal 'changed elsewhere', v.text, 'the model changing reloads the view'
    assert_equal 0, v.caret
    note.changed(:other) # a different aspect: nothing to reload
    assert_equal 'changed elsewhere', v.text
  end

  def test_a_model_without_a_writer_is_fine
    reader_only = Class.new(Model) { define_method(:text) { 'fixed' } }.new
    v = TextView.new(reader_only, Rectangle.from(0, 0, 100, 40))
    assert_equal 'fixed', v.text
    v.insert('!') # no text= to call: no error
    assert_equal '!fixed', v.text
  end

  # --- scrolling --------------------------------------------------------------------------------

  def test_the_view_scrolls_to_keep_the_caret_visible
    v = view(Array.new(30) { |i| "line #{i}" }.join("\n"), height: 60)
    assert_equal 6, v.visible_rows
    assert v.scrollbar_visible?
    v.move(:text_end)
    assert_equal 24, v.top_line, 'the last six lines show'
    v.move(:text_start)
    assert_equal 0, v.top_line
    v.place_caret(v.line_starts[10])
    assert_equal 5, v.top_line, 'caret on line 10: it is the bottom row'
    v.scroll_lines(-100)
    assert_equal 0, v.top_line
    v.scroll_lines(100)
    assert_equal 24, v.top_line
    assert_equal 30, v.scroll_total
  end

  def test_long_lines_scroll_sideways
    v = view('x' * 40, width: 100, height: 18, multiline: false)
    assert_equal 15, v.visible_cols
    refute v.scrollbar_visible?
    v.move(:end)
    assert_equal 26, v.left_col, 'the caret is the last visible column'
    v.move(:home)
    assert_equal 0, v.left_col
  end

  def test_a_short_view_still_shows_one_row
    v = view('a', height: 10)
    assert_equal 1, v.visible_rows
  end

  # --- drawing ----------------------------------------------------------------------------------

  def test_text_selection_and_caret_are_drawn
    v = view('A', width: 60, height: 20)
    plain = v.render
    assert_equal 0, plain[TextView::MARGIN_X, TextView::MARGIN_Y + 2], 'the A has ink where its first column starts'
    assert_equal 0xFFFFFF, plain[TextView::MARGIN_X + 5, TextView::MARGIN_Y], 'and its spacing column is blank'
    assert_equal 0xFFFFFF, plain[TextView::MARGIN_X - 1, TextView::MARGIN_Y], 'no caret while it has no focus'

    v.focused = true
    assert_equal 0, v.render[TextView::MARGIN_X - 1, TextView::MARGIN_Y], 'a caret at the start of the text when focused'

    v.select_all
    assert_equal 0, v.render[TextView::MARGIN_X + 5, TextView::MARGIN_Y], 'the selection is a solid bar'
  end

  def test_a_selected_newline_shows_as_an_extra_cell
    v = view("ab\ncd", width: 80, height: 30)
    v.place_caret(0)
    v.extend_selection(3) # "ab" and its newline
    picture = v.render
    assert_equal 0, picture[TextView::MARGIN_X + (2 * CELL) + 2, TextView::MARGIN_Y], 'the cell after "b" is selected'
    assert_equal 0xFFFFFF, picture[TextView::MARGIN_X + 2, TextView::MARGIN_Y + ROW + 4], 'the next line is not'
  end

  def test_a_text_view_shows_the_text_cursor_shape
    assert_equal 'xterm', view.cursor.tk_name
  end

  # --- the controller: mouse and keys through the window manager ---------------------------------

  def test_clicking_places_the_caret_and_gives_the_view_the_keyboard
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(5).x, cell(5).y, :red)
    @manager.mouse_up(top, cell(5).x, cell(5).y, :red)
    assert_equal 5, field.caret
    assert field.focused
    assert_same field.controller, @manager.focus_controller(top)
    @manager.mouse_move(top, 190, 50) # the pointer wanders: typing still goes to the field
    type(top, 'X')
    assert_equal 'helloX world', field.text
  end

  def test_focus_moves_between_text_views_and_is_drawn
    top = StandardSystemView.new('Two', nil, pt(200, 100))
    one = top.add_subview(TextView.new(nil, Rectangle.from(0, 0, 200, 40)))
    two = top.add_subview(TextView.new(nil, Rectangle.from(0, 50, 200, 40)))
    top.open(@manager)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    assert [one.focused, two.focused] == [true, false]
    @manager.mouse_down(top, 10, 60, :red)
    @manager.mouse_up(top, 10, 60, :red)
    assert [one.focused, two.focused] == [false, true]
    type(top, 'z')
    assert_equal ['', 'z'], [one.text, two.text]
  end

  def test_typing_and_editing_keys
    top, field = text_window
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    type(top, "ab\ncd")
    assert_equal "ab\ncd", field.text
    @manager.key(top, "\b", 'BackSpace')
    assert_equal "ab\nc", field.text
    @manager.key(top, '', 'Left')
    @manager.key(top, '', 'Delete')
    assert_equal "ab\n", field.text
    @manager.key(top, "\t", 'Tab')
    assert_equal "ab\n  ", field.text, 'Tab types two spaces'
    @manager.key(top, '', 'Shift_L') # a lone modifier key: ignored
    @manager.key(top, "\e", 'Escape')
    @manager.key(top, "\x01", 'a') # a control character: ignored
    @manager.key(top, "\u007f", 'Delete') # at the end: nothing to delete
    assert_equal "ab\n  ", field.text
  end

  def test_arrow_keys_with_shift_and_control
    top, field = text_window('foo bar baz')
    @manager.mouse_down(top, cell(0).x, cell(0).y, :red)
    @manager.mouse_up(top, cell(0).x, cell(0).y, :red)
    @manager.key(top, '', 'Right')
    @manager.key(top, '', 'Right', InputSensor::SHIFT)
    @manager.key(top, '', 'Right', InputSensor::SHIFT)
    assert_equal [1, 3], field.selection_range
    @manager.key(top, '', 'Right', InputSensor::CONTROL)
    assert_equal 7, field.caret, 'control moves by words (and drops the selection)'
    assert_nil field.selection_range
    @manager.key(top, '', 'Left', InputSensor::CONTROL | InputSensor::SHIFT)
    assert_equal [4, 7], field.selection_range, 'control and shift select back a word'
    @manager.key(top, '', 'Home')
    assert_equal 0, field.caret
    @manager.key(top, '', 'End')
    assert_equal 11, field.caret
  end

  def test_return_in_a_one_line_field_accepts
    got = []
    top, field = text_window('abc', multiline: false)
    field.on_accept = ->(text) { got << text }
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    @manager.key(top, "\r", 'Return')
    @manager.key(top, "\t", 'Tab')
    assert_equal ['abc'], got
    assert_equal 'abc', field.text, 'neither Return nor Tab typed anything'
  end

  def test_dragging_selects
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(2).x, cell(2).y, :red)
    @manager.mouse_move(top, cell(8).x, cell(8).y)
    @manager.mouse_move(top, 500, 500) # dragged right out of the field: selects to the end
    @manager.mouse_up(top, 500, 500, :red)
    assert_equal [2, 11], field.selection_range
    @manager.mouse_move(top, cell(1).x, cell(1).y) # not dragging any more
    assert_equal [2, 11], field.selection_range
  end

  def test_double_and_triple_clicks_and_shift_click
    now = 10.0
    @manager.clock = -> { now }
    top, field = text_window("one two three\nsecond line")
    click = lambda do |column, row = 0, state = 0|
      @manager.mouse_down(top, cell(column, row).x, cell(column, row).y, :red, state)
      @manager.mouse_up(top, cell(column, row).x, cell(column, row).y, :red)
      now += 0.1
    end
    click.call(5)
    assert_equal 5, field.caret
    click.call(5)
    assert_equal 'two', field.selected_text, 'double click: the word'
    click.call(5)
    assert_equal 'one two three', field.selected_text, 'triple click: the line'
    now += 5
    click.call(2)
    assert_nil field.selection_range
    click.call(9, 0, InputSensor::SHIFT)
    assert_equal [2, 9], field.selection_range, 'shift-click extends from the caret'
  end

  def test_the_wheel_and_scroll_bar_scroll_the_text
    top, field = text_window(Array.new(30) { |i| "line #{i}" }.join("\n"), extent: pt(200, 60))
    @manager.mouse_wheel(top, 20, 20, 3)
    assert_equal 3, field.top_line
    @manager.mouse_wheel(top, 20, 20, -1)
    assert_equal 2, field.top_line
    @manager.mouse_down(top, 195, 55, :red) # low on the scroll bar
    assert_operator field.top_line, :>, 15
    @manager.mouse_move(top, 195, 3)
    assert_equal 0, field.top_line
    @manager.mouse_up(top, 195, 3, :red)
    assert_nil field.selection_range, 'the scroll bar did not move the caret'
  end

  def test_command_keys_select_copy_cut_paste_and_undo
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(0).x, cell(0).y, :red)
    @manager.mouse_up(top, cell(0).x, cell(0).y, :red)
    assert_equal true, @manager.command_key(top, 'a')
    assert_equal 'hello world', field.selected_text
    assert_equal true, @manager.command_key(top, 'c')
    assert_equal 'hello world', Clipboard.text
    assert_equal true, @manager.command_key(top, 'X') # capital: the same key
    assert_equal '', field.text
    assert_equal true, @manager.command_key(top, 'v')
    assert_equal 'hello world', field.text
    assert_equal true, @manager.command_key(top, 'z')
    assert_equal '', field.text
    assert_equal false, @manager.command_key(top, 'q'), 'other combinations are left alone'
  end

  def test_the_default_yellow_menu_edits
    top, field = text_window('hello world', extent: pt(200, 120))
    @manager.mouse_down(top, 60, 40, :yellow)
    refute_nil top.popup
    assert_equal %w[Undo - Cut Copy Paste - Select\ all], top.popup.labels
    @manager.mouse_up(top, 60, 40, :yellow) # a click menu
    4.times { @manager.key(top, '', 'Down') } # Undo, Cut, Copy, Paste, Select all
    @manager.key(top, '', 'Return')
    assert_equal 'hello world', field.selected_text
    assert_nil top.popup
  end

  def test_a_custom_menu_replaces_the_default
    top, field = text_window('x', extent: pt(200, 120))
    field.controller.yellow_button_menu = PopUpMenu.new(%w[Only])
    @manager.mouse_down(top, 60, 40, :yellow)
    assert_equal ['Only'], top.popup.labels
    assert_nil field.controller.menu_for(:red)
    assert_nil field.controller.menu_for(:blue)
  end

  def test_keys_reach_the_focused_field_even_over_other_widgets
    top = StandardSystemView.new('Mixed', nil, pt(200, 100))
    field = top.add_subview(TextView.new(nil, Rectangle.from(0, 0, 200, 40)))
    pressed = []
    top.add_subview(ButtonView.new('b', Rectangle.from(0, 60, 40, 30)) { pressed << :b })
    top.open(@manager)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    @manager.mouse_move(top, 10, 70) # over the button
    type(top, 'ok')
    assert_equal 'ok', field.text
    assert_empty pressed
  end

  def test_closing_the_window_with_a_focused_field_is_clean
    top, = text_window('x')
    @manager.mouse_down(top, 10, 10, :red)
    top.close(@manager)
    assert_nil @manager.focus_controller(top)
  end

  # --- the Notes example ------------------------------------------------------------------------

  def test_notes_example_ties_a_list_a_menu_and_an_editor_together
    window = GraphicsExamples::Notes.open
    model = window.subviews.first.model
    list = window.subviews[0]
    field = window.subviews[2]
    assert_equal ['Welcome to Notes'], model.titles
    assert_equal 0, list.selection
    assert_match(/Click a note/, field.text)

    @manager.mouse_down(window, 20, 260, :red) # the New note button
    @manager.mouse_up(window, 20, 260, :red)
    assert_equal 2, model.notes.size
    assert_equal 1, list.selection, 'the new note is selected'
    assert_equal '', field.text
    assert_equal ['Welcome to Notes', '(empty)'], list.items

    @manager.mouse_down(window, 200, 20, :red) # into the editor
    @manager.mouse_up(window, 200, 20, :red)
    type(window, 'Shopping')
    assert_equal 'Shopping', model.notes[1]
    assert_equal ['Welcome to Notes', 'Shopping'], list.items, 'the list follows what is typed'

    @manager.mouse_down(window, 20, 8, :red) # back to the first note
    @manager.mouse_up(window, 20, 8, :red)
    assert_equal 0, model.selected
    assert_match(/Welcome/, field.text)
    assert_equal 0, field.caret

    @manager.mouse_down(window, 20, 100, :yellow) # the list menu: New note, Duplicate, -, Delete
    @manager.mouse_up(window, 20, 100, :yellow)
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Return') # Duplicate
    assert_equal 3, model.notes.size
    assert_equal model.notes[0], model.notes[1]

    @manager.mouse_down(window, 20, 100, :yellow)
    @manager.mouse_up(window, 20, 100, :yellow)
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Return') # Delete
    assert_equal 2, model.notes.size
    assert_equal ['Welcome to Notes', 'Shopping'], model.titles
  end

  def test_notes_always_keep_one_note
    model = GraphicsExamples::Notes.new
    model.delete_selected
    assert_equal 1, model.notes.size
    model.select(5) # no such note
    assert_equal 0, model.selected
  end
end
