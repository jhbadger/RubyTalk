# frozen_string_literal: true

require 'fileutils'

module RubyTalk
  # Small per-user settings kept outside any image folder: just the folder
  # that was chosen last time, so the folder chooser can start there.
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

    # Where the folder chooser should start: the last folder used, else ~/RubyTalk
    # if it exists, else the home directory.
    def last_directory
      path = File.read(last_directory_file, encoding: 'UTF-8').strip
      File.directory?(path) ? path : default_directory
    rescue SystemCallError
      default_directory
    end

    def default_directory
      suggested = File.join(Dir.home, 'RubyTalk')
      File.directory?(suggested) ? suggested : Dir.home
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
