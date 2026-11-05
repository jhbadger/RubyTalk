# frozen_string_literal: true

require 'zlib'

module RubyTalk
  # The RubyTalk icon, drawn in code (standard library only, no image files):
  # a ruby gem inside a Smalltalk-style speech bubble, on a ruby-red tile.
  #
  # Shapes are described by signed distance functions, so every size is
  # anti-aliased analytically and stays crisp from 16 to 1024 pixels.
  module Icon
    # Colours are [r, g, b] in 0..255. y runs downward; coordinates are the unit square.
    WHITE = [255, 255, 255].freeze
    BLACK = [0, 0, 0].freeze
    TILE_TOP = [226, 40, 60].freeze
    TILE_BOTTOM = [118, 8, 30].freeze
    BUBBLE_TOP = [255, 253, 251].freeze
    BUBBLE_BOTTOM = [241, 228, 231].freeze
    BUBBLE_SHADOW = [64, 0, 14].freeze
    GEM_OUTLINE = [92, 4, 28].freeze
    GEM_BASE = [150, 10, 42].freeze

    # Apple's icon grid: the tile fills about 80% of the canvas, with a soft shadow.
    TILE_HALF = 0.402
    TILE_RADIUS = 0.18
    TILE_MIN = 0.5 - TILE_HALF

    # Speech bubble: rounded body (cx, cy, half-width, half-height, radius) plus a tail.
    BUBBLE = [0.5, 0.44, 0.33, 0.25, 0.11].freeze
    BUBBLE_Y0 = 0.19
    BUBBLE_Y1 = 0.85

    # A convex polygon as half-planes [nx, ny, c] with the normal pointing outward:
    # distance(x, y) is negative inside, positive outside (exact inside, a close
    # under-estimate near corners outside, which is all anti-aliasing needs).
    Polygon = Struct.new(:edges) do
      def distance(x, y)
        worst = -Float::INFINITY
        edges.each do |nx, ny, c|
          d = (nx * x) + (ny * y) - c
          worst = d if d > worst
        end
        worst
      end
    end

    def self.polygon(points)
      cx = points.sum { |p| p[0] } / points.size.to_f
      cy = points.sum { |p| p[1] } / points.size.to_f
      edges = points.each_with_index.map do |(x1, y1), i|
        x2, y2 = points[(i + 1) % points.size]
        dx = x2 - x1
        dy = y2 - y1
        length = Math.hypot(dx, dy)
        nx = dy / length
        ny = -dx / length
        c = (nx * x1) + (ny * y1)
        nx, ny, c = -nx, -ny, -c if (nx * cx) + (ny * cy) - c.to_f > 0
        [nx, ny, c]
      end
      Polygon.new(edges.freeze)
    end

    TAIL = polygon([[0.27, 0.66], [0.45, 0.66], [0.25, BUBBLE_Y1]])

    # The gem: crown on top, pavilion below, six facets.
    GEM_B = [0.40, 0.27].freeze
    GEM_C = [0.60, 0.27].freeze
    GEM_A = [0.30, 0.39].freeze
    GEM_D = [0.70, 0.39].freeze
    GEM_G1 = [0.42, 0.39].freeze
    GEM_G2 = [0.58, 0.39].freeze
    GEM_P = [0.50, 0.62].freeze
    GEM_OUTLINE_SHAPE = polygon([GEM_B, GEM_C, GEM_D, GEM_P, GEM_A])
    FACETS = [
      [polygon([GEM_B, GEM_A, GEM_G1]),        [236, 62, 88]],  # crown, left
      [polygon([GEM_B, GEM_C, GEM_G2, GEM_G1]), [255, 118, 134]], # table (catches the light)
      [polygon([GEM_C, GEM_D, GEM_G2]),        [206, 36, 66]],  # crown, right
      [polygon([GEM_A, GEM_G1, GEM_P]),        [186, 22, 54]],  # pavilion, left
      [polygon([GEM_G1, GEM_G2, GEM_P]),       [226, 46, 74]],  # pavilion, centre
      [polygon([GEM_G2, GEM_D, GEM_P]),        [146, 12, 42]]   # pavilion, right
    ].freeze

    module_function

    # Signed distance to a rounded rectangle (negative inside).
    def round_rect(x, y, cx, cy, half_w, half_h, radius)
      qx = (x - cx).abs - (half_w - radius)
      qy = (y - cy).abs - (half_h - radius)
      Math.hypot([qx, 0.0].max, [qy, 0.0].max) + [[qx, qy].max, 0.0].min - radius
    end

    def bubble_distance(x, y)
      body = round_rect(x, y, *BUBBLE)
      tail = TAIL.distance(x, y)
      body < tail ? body : tail
    end

    # Pixel coverage 0..1 from a signed distance, for a canvas of +scale+ pixels.
    def coverage(distance, scale)
      value = 0.5 - (distance * scale)
      value.clamp(0.0, 1.0)
    end

    # Soft shadow falloff: 1 inside the shape, fading to 0 over +blur+ outside it.
    def soft(distance, blur)
      return 1.0 if distance <= 0.0

      ((1.0 - (distance / blur)).clamp(0.0, 1.0))**2
    end

    def mix(from, to, t)
      t = t.clamp(0.0, 1.0)
      [from[0] + ((to[0] - from[0]) * t), from[1] + ((to[1] - from[1]) * t), from[2] + ((to[2] - from[2]) * t)]
    end

    # "Over" compositing into a premultiplied accumulator [r*a, g*a, b*a, a] (colour 0..255).
    def blend!(acc, color, alpha)
      return if alpha <= 0.0

      inverse = 1.0 - alpha
      acc[0] = (color[0] * alpha) + (acc[0] * inverse)
      acc[1] = (color[1] * alpha) + (acc[1] * inverse)
      acc[2] = (color[2] * alpha) + (acc[2] * inverse)
      acc[3] = alpha + (acc[3] * inverse)
    end

    # RGBA bytes of the icon at (x, y) in the unit square.
    def sample(x, y, scale)
      acc = [0.0, 0.0, 0.0, 0.0]
      blend!(acc, BLACK, soft(round_rect(x, y - 0.014, 0.5, 0.5, TILE_HALF, TILE_HALF, TILE_RADIUS), 0.04) * 0.32)

      tile = coverage(round_rect(x, y, 0.5, 0.5, TILE_HALF, TILE_HALF, TILE_RADIUS), scale)
      if tile.positive?
        blend!(acc, mix(TILE_TOP, TILE_BOTTOM, (y - TILE_MIN) / (2 * TILE_HALF)), tile)
        glow = (1.0 - (Math.hypot(x - 0.32, y - 0.2) / 0.6)).clamp(0.0, 1.0)
        blend!(acc, WHITE, tile * 0.18 * glow * glow)
        draw_bubble(acc, x, y, scale, tile)
      end
      finish(acc)
    end

    def draw_bubble(acc, x, y, scale, tile)
      blend!(acc, BUBBLE_SHADOW, soft(bubble_distance(x, y - 0.018), 0.035) * 0.38 * tile)
      body = coverage(bubble_distance(x, y), scale)
      return unless body.positive?

      blend!(acc, mix(BUBBLE_TOP, BUBBLE_BOTTOM, (y - BUBBLE_Y0) / (BUBBLE_Y1 - BUBBLE_Y0)), body)
      draw_gem(acc, x, y, scale)
    end

    def draw_gem(acc, x, y, scale)
      outline = GEM_OUTLINE_SHAPE.distance(x, y)
      blend!(acc, GEM_OUTLINE, coverage(outline - 0.008, scale))
      silhouette = coverage(outline, scale)
      return unless silhouette.positive?

      blend!(acc, GEM_BASE, silhouette)
      FACETS.each do |shape, color|
        facet = coverage(shape.distance(x, y), scale)
        blend!(acc, color, facet) if facet.positive?
      end
      # A small four-point sparkle on the table.
      reach = Math.sqrt((x - 0.452).abs / 0.04) + Math.sqrt((y - 0.308).abs / 0.04)
      blend!(acc, WHITE, (1.0 - reach).clamp(0.0, 1.0) * 0.9) if reach < 1.0
    end

    # Premultiplied accumulator -> straight-alpha [r, g, b, a] bytes.
    def finish(acc)
      alpha = acc[3]
      return [0, 0, 0, 0] if alpha <= 0.0

      [(acc[0] / alpha).round.clamp(0, 255), (acc[1] / alpha).round.clamp(0, 255),
       (acc[2] / alpha).round.clamp(0, 255), (alpha * 255).round.clamp(0, 255)]
    end

    # --- PNG and ICNS ------------------------------------------------------

    def render_png(size)
      rows = Array.new(size) do |py|
        y = (py + 0.5) / size
        bytes = [0] # PNG filter type 0 (none)
        size.times { |px| bytes.concat(sample((px + 0.5) / size, y, size)) }
        bytes.pack('C*')
      end
      png_file(size, rows.join)
    end

    def png_file(size, raw)
      "\x89PNG\r\n\x1a\n".b +
        png_chunk('IHDR', [size, size, 8, 6, 0, 0, 0].pack('NNCCCCC')) +
        png_chunk('IDAT', Zlib::Deflate.deflate(raw, 9)) +
        png_chunk('IEND', '')
    end

    def png_chunk(tag, data)
      [data.bytesize].pack('N') + tag.b + data.b + [Zlib.crc32(tag.b + data.b)].pack('N')
    end

    # Base64 PNG for Tk's `image create photo -data` (the window / Dock icon).
    def png_base64(size = 128)
      [render_png(size)].pack('m0')
    end

    # ICNS entry types that hold PNG data, with the pixel size of each.
    ICNS_TYPES = [['icp4', 16], ['icp5', 32], ['ic11', 32], ['ic12', 64], ['ic07', 128],
                  ['ic13', 256], ['ic08', 256], ['ic14', 512], ['ic09', 512], ['ic10', 1024]].freeze

    # A complete .icns file, written directly (no iconutil needed). The 1024-pixel
    # rendering takes a few seconds, so the result is kept for the life of the process.
    def make_icns
      @icns ||= begin
        pngs = {}
        body = ''.b
        ICNS_TYPES.each do |tag, size|
          pngs[size] ||= render_png(size)
          body << tag.b << [pngs[size].bytesize + 8].pack('N') << pngs[size]
        end
        ('icns'.b + [body.bytesize + 8].pack('N') + body).freeze
      end
    end
  end
end
