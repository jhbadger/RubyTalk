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
      # Old macOS versions pass a process serial number (-psn_...) to apps.
      args = argv.reject { |arg| arg.start_with?('-psn_') }
      rest = parser(options).parse(args)

      if options[:icon_png]
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
        opts.on('--selftest', 'exercise the windows with real Tk in a temporary directory, then exit') do
          options[:selftest] = true
        end
        opts.separator ''
        opts.separator 'macOS app bundle:'
        opts.on('--build-app [DIR]', 'build RubyTalk.app in DIR (default: current directory), then exit') do |dir|
          options[:build_app] = dir || Dir.pwd
        end
        opts.on('--workdir DIR', 'with --build-app: where the app keeps changes.rb (default: ~/RubyTalk)') do |dir|
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

    def write_icon(size, path)
      File.binwrite(path, Icon.render_png(size))
      puts path
    end

    def build_app(options)
      build = { link: options[:link] || false }
      build[:workdir] = options[:workdir] if options[:workdir]
      app = AppBundle.build(options[:build_app], **build)
      puts app
      warn "Move it to /Applications (or ~/Applications) if you like; it keeps changes.rb in " \
           "#{options[:workdir] || File.join(Dir.home, AppBundle::NAME)}."
    end

    def start(options)
      dir = File.expand_path(options[:dir] || Dir.pwd)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir)
      RubyTalk.run(dir: dir, selftest: options[:selftest] || false)
    end
  end
end
