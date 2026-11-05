# frozen_string_literal: true

# Tests for the icon renderer, the .icns writer, the macOS app bundle builder and
# the command line. No display needed.
#   ruby test/test_icon.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'open3'
require 'zlib'
require 'rubytalk'

class IconTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('rubytalk-icon')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # Minimal PNG decoder for what Icon writes (8-bit RGBA, filter 0).
  def decode_png(data)
    assert_equal "\x89PNG\r\n\x1a\n".b, data.byteslice(0, 8)
    offset = 8
    chunks = {}
    while offset < data.bytesize
      length = data.byteslice(offset, 4).unpack1('N')
      tag = data.byteslice(offset + 4, 4)
      body = data.byteslice(offset + 8, length)
      crc = data.byteslice(offset + 8 + length, 4).unpack1('N')
      assert_equal Zlib.crc32(tag + body), crc, "bad CRC in #{tag}"
      chunks[tag] = body
      offset += 12 + length
    end
    width, height, depth, color = chunks['IHDR'].unpack('NNCC')
    assert_equal [8, 6], [depth, color]
    raw = Zlib::Inflate.inflate(chunks['IDAT'])
    stride = (width * 4) + 1
    assert_equal stride * height, raw.bytesize
    pixel = lambda do |x, y|
      assert_equal 0, raw.getbyte(y * stride), 'filter type'
      raw.byteslice((y * stride) + 1 + (x * 4), 4).unpack('C4')
    end
    [width, height, pixel]
  end

  def at(pixel, size, fx, fy)
    pixel.call((fx * size).to_i, (fy * size).to_i)
  end

  def test_png_is_valid_and_shows_the_design
    size = 128
    width, height, pixel = decode_png(RubyTalk::Icon.render_png(size))
    assert_equal [size, size], [width, height]

    assert_equal 0, at(pixel, size, 0.01, 0.01)[3], 'canvas corner is transparent'
    tile = at(pixel, size, 0.5, 0.12)
    assert_equal 255, tile[3]
    assert_operator tile[0], :>, 180, 'tile is ruby red'
    assert_operator tile[1], :<, 90
    bubble = at(pixel, size, 0.22, 0.30)
    assert(bubble.first(3).all? { |c| c > 225 }, "bubble is near-white, got #{bubble.inspect}")
    table = at(pixel, size, 0.5, 0.33)
    assert_operator table[0], :>, 200, 'gem table is light red'
    assert_operator table[1], :<, 170
    assert_equal 255, at(pixel, size, 0.5, 0.5)[3]
  end

  def test_every_icns_size_renders
    [16, 32, 64, 128, 256].each do |size|
      width, height, = decode_png(RubyTalk::Icon.render_png(size))
      assert_equal [size, size], [width, height]
    end
  end

  def test_base64_png_round_trips
    encoded = RubyTalk::Icon.png_base64(32)
    refute encoded.frozen?, 'the tk gem mutates strings it is given'
    assert_equal RubyTalk::Icon.render_png(32), encoded.unpack1('m0')
  end

  def test_icns_container
    icns = RubyTalk::Icon.make_icns
    assert_equal 'icns', icns.byteslice(0, 4)
    assert_equal icns.bytesize, icns.byteslice(4, 4).unpack1('N')
    offset = 8
    seen = []
    while offset < icns.bytesize
      tag = icns.byteslice(offset, 4)
      length = icns.byteslice(offset + 4, 4).unpack1('N')
      assert_equal "\x89PNG".b, icns.byteslice(offset + 8, 4), "#{tag} payload is a PNG"
      seen << tag
      offset += length
    end
    assert_equal icns.bytesize, offset
    assert_equal RubyTalk::Icon::ICNS_TYPES.map(&:first).sort, seen.sort
  end

  # --- app bundle ----------------------------------------------------------

  def build(**options)
    workdir = File.join(@dir, 'work')
    RubyTalk::AppBundle.build(@dir, workdir: workdir, **options)
  end

  def test_bundle_layout_and_plist
    app = build
    assert_equal File.join(@dir, 'RubyTalk.app'), app
    %w[Contents/Info.plist Contents/MacOS/RubyTalk Contents/Resources/RubyTalk.icns
       Contents/Resources/rubytalk/bin/rubytalk Contents/Resources/rubytalk/lib/rubytalk.rb].each do |path|
      assert File.file?(File.join(app, path)), "missing #{path}"
    end
    assert File.executable?(File.join(app, 'Contents/MacOS/RubyTalk'))
    plist = File.read(File.join(app, 'Contents/Info.plist'))
    assert_match(%r{<key>CFBundleIconFile</key>\s*<string>RubyTalk</string>}, plist)
    assert_match(%r{<key>CFBundleExecutable</key>\s*<string>RubyTalk</string>}, plist)
    assert_match(%r{<key>CFBundleIdentifier</key>\s*<string>org.badgerjh.rubytalk</string>}, plist)
    assert_match(%r{<key>NSHighResolutionCapable</key>\s*<true/>}, plist)
    assert_equal RubyTalk::Icon.make_icns, File.binread(File.join(app, 'Contents/Resources/RubyTalk.icns'))
  end

  def test_copied_bundle_launcher_runs_ruby_talk
    app = build
    launcher = File.join(app, 'Contents/MacOS/RubyTalk')
    out, status = Open3.capture2e('sh', launcher, '--help')
    assert status.success?, out
    assert_match(/usage: rubytalk/, out)
    png = File.join(@dir, 'from-bundle.png')
    out, status = Open3.capture2e('sh', launcher, '--icon-png', '16', png)
    assert status.success?, out
    assert File.size(png).positive?
  end

  def test_launcher_passes_the_work_directory
    app = build
    launcher = File.read(File.join(app, 'Contents/MacOS/RubyTalk'))
    assert_includes launcher, "--dir #{File.join(@dir, 'work')}"
    assert_match(/export LANG=/, launcher)
    assert_match(%r{\Aexec |^exec }, launcher)
  end

  def test_linked_bundle_points_at_this_checkout_and_copies_no_code
    app = build(link: true)
    launcher = File.read(File.join(app, 'Contents/MacOS/RubyTalk'))
    assert_includes launcher, File.join(RubyTalk::AppBundle.repo_root, 'bin', 'rubytalk')
    refute File.exist?(File.join(app, 'Contents/Resources/rubytalk')), 'link mode copies nothing'
    out, status = Open3.capture2e('sh', File.join(app, 'Contents/MacOS/RubyTalk'), '--help')
    assert status.success?, out
  end

  def test_paths_with_spaces_are_quoted
    spaced = File.join(@dir, 'my work dir')
    app = RubyTalk::AppBundle.build(@dir, workdir: spaced)
    launcher = File.read(File.join(app, 'Contents/MacOS/RubyTalk'))
    assert_includes launcher, 'my\ work\ dir'
  end

  def test_rebuilding_replaces_the_bundle
    app = build
    File.write(File.join(app, 'stale'), 'x')
    build
    refute File.exist?(File.join(app, 'stale'))
  end

  def test_stable_ruby_prefers_the_homebrew_opt_symlink
    cellar = File.join(@dir, 'Cellar/ruby/9.9.9/bin/ruby')
    opt = File.join(@dir, 'opt/ruby/bin/ruby')
    [cellar, opt].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/bin/sh\n")
      FileUtils.chmod(0o755, path)
    end
    RbConfig.stub(:ruby, cellar) { assert_equal opt, RubyTalk::AppBundle.stable_ruby }
    FileUtils.rm(opt)
    RbConfig.stub(:ruby, cellar) { assert_equal cellar, RubyTalk::AppBundle.stable_ruby }
    RbConfig.stub(:ruby, '/usr/bin/ruby') { assert_equal '/usr/bin/ruby', RubyTalk::AppBundle.stable_ruby }
  end

  def test_plist_escapes_xml
    xml = RubyTalk::AppBundle.plist_xml('A&B' => '<x>', 'Flag' => false, 'N' => 3)
    assert_includes xml, '<key>A&amp;B</key>'
    assert_includes xml, '<string>&lt;x&gt;</string>'
    assert_includes xml, '<false/>'
    assert_includes xml, '<integer>3</integer>'
  end

  # --- command line --------------------------------------------------------

  def test_cli_icon_png_and_psn_argument
    out = File.join(@dir, 'cli.png')
    stdout, = capture_io { RubyTalk::CLI.main(['-psn_0_12345', '--icon-png', '24', out]) }
    assert_equal "#{out}\n", stdout
    width, = decode_png(File.binread(out))
    assert_equal 24, width
  end

  def test_cli_build_app
    workdir = File.join(@dir, 'wd')
    stdout, = capture_io { RubyTalk::CLI.main(['--build-app', @dir, '--workdir', workdir]) }
    assert_equal "#{File.join(@dir, 'RubyTalk.app')}\n", stdout
    assert_includes File.read(File.join(@dir, 'RubyTalk.app/Contents/MacOS/RubyTalk')), workdir
  end
end
