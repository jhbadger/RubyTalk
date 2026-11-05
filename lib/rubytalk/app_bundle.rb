# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'shellwords'

module RubyTalk
  # Builds RubyTalk.app: a macOS application bundle that starts RubyTalk with the
  # icon in the Dock and Finder. The bundle is a shell launcher plus the icon and
  # an Info.plist; it runs the same Ruby that built it.
  #
  #   rubytalk --build-app [DIR]            copy the code into the app (self-contained)
  #   rubytalk --build-app DIR --link       run the code in place (edits take effect at once)
  #   rubytalk --build-app DIR --workdir D  always use folder D for changes.rb
  #                                         (default: the app asks, with a folder chooser, at each start)
  module AppBundle
    NAME = 'RubyTalk'
    IDENTIFIER = 'org.badgerjh.rubytalk'

    module_function

    # Returns the path of the new bundle.
    def build(dest, workdir: nil, link: false)
      app = File.join(File.expand_path(dest), "#{NAME}.app")
      FileUtils.rm_rf(app)
      macos = File.join(app, 'Contents', 'MacOS')
      resources = File.join(app, 'Contents', 'Resources')
      FileUtils.mkdir_p([macos, resources])

      File.binwrite(File.join(resources, "#{NAME}.icns"), Icon.make_icns)
      script = link ? link_script : copy_code(resources)
      write_launcher(File.join(macos, NAME), script, workdir && File.expand_path(workdir))
      File.write(File.join(app, 'Contents', 'Info.plist'), plist_xml(info_plist))
      app
    end

    def repo_root
      File.dirname(RubyTalk::LIB_DIR)
    end

    # --link: the launcher points at bin/rubytalk where it lives now.
    def link_script
      Shellwords.escape(File.join(repo_root, 'bin', 'rubytalk'))
    end

    # Default: copy bin/ and lib/ into Resources, so the app keeps working if the
    # source folder moves (and stays as it was built until you rebuild).
    def copy_code(resources)
      target = File.join(resources, 'rubytalk')
      FileUtils.mkdir_p(target)
      %w[bin lib LICENSE].each do |item|
        source = File.join(repo_root, item)
        FileUtils.cp_r(source, target) if File.exist?(source)
      end
      '"$(dirname "$0")/../Resources/rubytalk/bin/rubytalk"'
    end

    # Finder starts apps in "/", so the launcher must say which folder holds
    # changes.rb: a fixed one (--dir) or "ask me" (--choose-dir).
    def write_launcher(path, script, workdir)
      folder = workdir ? "--dir #{Shellwords.escape(workdir)}" : '--choose-dir'
      File.write(path, <<~SH)
        #!/bin/sh
        # #{NAME}.app launcher: Finder starts apps with almost no environment.
        export LANG="${LANG:-en_US.UTF-8}"
        exec #{Shellwords.escape(stable_ruby)} #{script} #{folder} "$@"
      SH
      FileUtils.chmod(0o755, path)
    end

    # Homebrew installs Ruby under a versioned Cellar path that changes on every
    # upgrade; its opt/ symlink does not. Prefer that when it exists.
    def stable_ruby
      ruby = RbConfig.ruby
      match = ruby.match(%r{\A(.*)/Cellar/([^/]+)/[^/]+/bin/ruby\z})
      return ruby unless match

      opt = "#{match[1]}/opt/#{match[2]}/bin/ruby"
      File.executable?(opt) ? opt : ruby
    end

    def info_plist
      {
        'CFBundleName' => NAME,
        'CFBundleDisplayName' => NAME,
        'CFBundleIdentifier' => IDENTIFIER,
        'CFBundleExecutable' => NAME,
        'CFBundleIconFile' => NAME,
        'CFBundlePackageType' => 'APPL',
        'CFBundleShortVersionString' => RubyTalk::VERSION,
        'CFBundleVersion' => RubyTalk::VERSION,
        'LSApplicationCategoryType' => 'public.app-category.developer-tools',
        'NSHighResolutionCapable' => true
      }
    end

    # A minimal XML property list writer (strings, booleans, integers).
    def plist_xml(hash)
      body = hash.map { |key, value| "  <key>#{escape(key)}</key>\n  #{plist_value(value)}\n" }.join
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        #{body.chomp}
        </dict>
        </plist>
      XML
    end

    def plist_value(value)
      case value
      when true then '<true/>'
      when false then '<false/>'
      when Integer then "<integer>#{value}</integer>"
      else "<string>#{escape(value)}</string>"
      end
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
