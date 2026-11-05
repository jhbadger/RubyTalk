# frozen_string_literal: true

require 'fileutils'

module RubyTalk
  # Small per-user settings kept outside any image folder:
  #   last_dir  the folder RubyTalk was last run in (`rubytalk --last-dir`, which RubyTalk.app uses,
  #             starts there; the very first time it is your home directory)
  #   layout    the size and position each kind of window had last time ("browser 900x600+80+90")
  module Preferences
    # Tk's geometry string: WIDTHxHEIGHT+X+Y (the offsets can be negative).
    GEOMETRY = /\A(\d+)x(\d+)([+-]\d+)([+-]\d+)\z/.freeze

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

    def layout_file
      File.join(directory, 'layout')
    end

    # { "browser" => "900x600+80+90", ... }; lines that are not a kind and a geometry are ignored.
    def layout
      File.readlines(layout_file, chomp: true, encoding: 'UTF-8').each_with_object({}) do |line, entries|
        kind, geometry = line.split(' ', 2)
        entries[kind] = geometry.strip if kind && geometry && geometry.strip.match?(GEOMETRY)
      end
    rescue SystemCallError
      {}
    end

    # Merge +entries+ ({ kind => geometry }) into the saved layout. Returns the merged layout, or nil
    # if it could not be written (remembering is a convenience, never a reason to fail).
    def save_layout(entries)
      merged = layout.merge(entries.transform_keys(&:to_s).select { |_kind, geometry| geometry.to_s.match?(GEOMETRY) })
      FileUtils.mkdir_p(directory)
      File.write(layout_file, "#{merged.map { |kind, geometry| "#{kind} #{geometry}" }.join("\n")}\n", encoding: 'UTF-8')
      merged
    rescue SystemCallError
      nil
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
