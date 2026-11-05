# frozen_string_literal: true

# RubyTalk: a Smalltalk-80 style programming environment for Ruby, built on Ruby/Tk.
#
#   Transcript   global text stream (Transcript.show, .cr, .tab, ...) and a window
#   Workspace    editor with do it / print it / inspect it
#   Browser      class and method browser; Accept defines or redefines code
#   changes.rb   log of class/method changes, replayed at startup, saved at exit

module RubyTalk
  VERSION = '0.1.0'
  LIB_DIR = File.expand_path(__dir__)

  class << self
    attr_accessor :changes

    # Absolute path of bin/rubytalk as it was started (needed to restart in another folder).
    attr_accessor :script_path

    # Loads changes.rb from +dir+, then opens the environment (Transcript, a
    # System Browser and a Workspace). With selftest: true it runs the built-in
    # GUI checks in a temporary directory instead and exits. The folder is remembered
    # (Preferences) so `--last-dir` can start there next time.
    def run(dir: Dir.pwd, selftest: false)
      begin
        require_relative 'rubytalk/gui'
      rescue LoadError => e
        abort "RubyTalk needs the 'tk' gem (#{e.message}).\n  brew install tcl-tk && gem install tk"
      end
      if selftest
        require 'tmpdir'
        dir = Dir.mktmpdir('rubytalk-selftest')
        at_exit { FileUtils.remove_entry(dir) if File.directory?(dir) }
      end
      Preferences.remember_directory(File.expand_path(dir)) unless selftest
      setup(dir)
      GUI.start(selftest: selftest)
    end

    # Everything except the windows: useful for tests and scripts.
    def setup(dir = Dir.pwd)
      self.changes = ChangeSet.new(File.join(File.expand_path(dir), 'changes.rb'))
      changes.load!
      changes.autosave = true
      @exit_hook ||= at_exit { save_changes }
      changes
    end

    # Switch to another folder by starting afresh there: the classes of the current
    # image are loaded into this Ruby and cannot be unloaded. Everything accepted so
    # far is already saved. The process is replaced (same process id), which keeps
    # the macOS Dock/app association. Returns only if the replacement failed.
    def restart_in(dir)
      dir = File.expand_path(dir)
      save_changes
      Preferences.remember_directory(dir)
      replace_process(RbConfig.ruby, script_path || File.join(File.dirname(LIB_DIR), 'bin', 'rubytalk'), '--dir', dir)
    end

    def replace_process(*command)
      exec(*command)
    end

    # Writes changes.rb if anything changed since the last save. Safe to call repeatedly.
    def save_changes
      return nil unless changes

      path = changes.save!
      warn "RubyTalk: changes saved to #{path}" if path
      path
    end
  end
end

require_relative 'rubytalk/transcript'
::Transcript = RubyTalk::TranscriptStream.new unless defined?(::Transcript)
require_relative 'rubytalk/evaluator'
require_relative 'rubytalk/source'
require_relative 'rubytalk/changes'
require_relative 'rubytalk/reflection'
require_relative 'rubytalk/compiler'
require_relative 'rubytalk/search'
require_relative 'rubytalk/preferences'
require_relative 'rubytalk/icon'
require_relative 'rubytalk/app_bundle'
require_relative 'rubytalk/cli'
