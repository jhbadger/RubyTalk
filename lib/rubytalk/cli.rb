# frozen_string_literal: true

require 'optparse'
require 'fileutils'

module RubyTalk
  # Command line for bin/rubytalk.
  module CLI
    module_function

    # Starts RubyTalk, or performs one of the build actions and returns.
    def main(argv)
      options = {}
      RubyTalk.script_path = File.expand_path($PROGRAM_NAME) # before anything changes directory
      # Old macOS versions pass a process serial number (-psn_...) to apps.
      args = argv.reject { |arg| arg.start_with?('-psn_') }
      rest = parser(options).parse(args)

      if options[:export]
        export(options)
      elsif options[:icon_png]
        write_icon(options[:icon_png], rest.first || "#{AppBundle::NAME}.png")
      elsif options[:build_app]
        build_app(options)
      else
        start(options)
      end
    end

    def parser(options)
      OptionParser.new do |opts|
        opts.banner = "usage: rubytalk [options]\n  Run from the directory containing (or to contain) changes.rb."
        opts.on('--dir DIR', 'directory holding changes.rb (default: the current directory)') { |d| options[:dir] = d }
        opts.on('--last-dir', 'use the folder RubyTalk was last run in (your home directory the first time)') do
          options[:last] = true
        end
        opts.on('--export FILE', "write the folder's changes.rb as plain Ruby to FILE, then exit") { |file| options[:export] = file }
        opts.on('--selftest', 'exercise the windows with real Tk in a temporary directory, then exit') do
          options[:selftest] = true
        end
        opts.separator ''
        opts.separator 'macOS app bundle:'
        opts.on('--build-app [DIR]', 'build RubyTalk.app in DIR (default: current directory), then exit') do |dir|
          options[:build_app] = dir || Dir.pwd
        end
        opts.on('--workdir DIR', 'with --build-app: always use DIR for changes.rb (default: the app uses the last folder, see --last-dir)') do |dir|
          options[:workdir] = dir
        end
        opts.on('--link', 'with --build-app: run the code in place instead of copying it into the app') do
          options[:link] = true
        end
        opts.on('--icon-png SIZE', Integer, 'write the icon as a SIZE-pixel PNG (next argument: file name) and exit') do |size|
          options[:icon_png] = size
        end
        opts.on('-h', '--help', 'show this help') do
          puts opts
          exit
        end
      end
    end

    # File out without opening any window: the folder's changes as plain Ruby.
    def export(options)
      RubyTalk.setup(resolve_directory(options))
      File.write(options[:export], Exchange.all_source, encoding: 'UTF-8')
      puts options[:export]
    end

    def write_icon(size, path)
      File.binwrite(path, Icon.render_png(size))
      puts path
    end

    def build_app(options)
      build = { link: options[:link] || false }
      build[:workdir] = options[:workdir] if options[:workdir]
      app = AppBundle.build(options[:build_app], **build)
      puts app
      where = if options[:workdir]
                "always keeps changes.rb in #{options[:workdir]}"
              else
                'opens in the folder you used last (your home directory the first time); System > Change Directory switches'
              end
      warn "Move it to /Applications (or ~/Applications) if you like; it #{where}."
    end

    # --dir wins, then --last-dir, else the current directory.
    def resolve_directory(options)
      dir = options[:dir] || (options[:last] ? Preferences.last_directory : Dir.pwd)
      File.expand_path(dir)
    end

    def start(options)
      dir = resolve_directory(options)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir)
      RubyTalk.run(dir: dir, selftest: options[:selftest] || false)
    end
  end
end
