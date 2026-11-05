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

    # Loads changes.rb from +dir+, then opens the environment (Transcript, a
    # System Browser and a Workspace). With selftest: true it runs the built-in
    # GUI checks in a temporary directory instead and exits. With choose: true it
    # first asks (folder chooser) which folder to use, and quits quietly if you cancel.
    def run(dir: Dir.pwd, selftest: false, choose: false)
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
      if choose
        dir = GUI.choose_directory or return
        FileUtils.mkdir_p(dir)
        Dir.chdir(dir)
      end
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
