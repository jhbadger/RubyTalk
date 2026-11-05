# frozen_string_literal: true

require 'fileutils'

module RubyTalk
  # Small per-user settings kept outside any image folder: just the folder
  # RubyTalk was last run in. `rubytalk --last-dir` (what RubyTalk.app uses)
  # starts there; the very first time it is your home directory.
  module Preferences
    module_function

    def directory
      if RUBY_PLATFORM.include?('darwin')
        File.join(Dir.home, 'Library', 'Application Support', 'RubyTalk')
      else
        File.join(ENV['XDG_CONFIG_HOME'] || File.join(Dir.home, '.config'), 'rubytalk')
      end
    end

    def last_directory_file
      File.join(directory, 'last_dir')
    end

    # The folder used last time, or the home directory if there is none (or it has gone).
    def last_directory
      path = File.read(last_directory_file, encoding: 'UTF-8').strip
      File.directory?(path) ? path : default_directory
    rescue SystemCallError
      default_directory
    end

    def default_directory
      Dir.home
    end

    def remember_directory(path)
      FileUtils.mkdir_p(directory)
      File.write(last_directory_file, "#{path}\n", encoding: 'UTF-8')
      path
    rescue SystemCallError
      nil # remembering is a convenience; never let it stop startup
    end
  end
end
