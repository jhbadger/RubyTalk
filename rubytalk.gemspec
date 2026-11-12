# frozen_string_literal: true

require_relative 'lib/rubytalk/version'

Gem::Specification.new do |spec|
  spec.name = 'rubytalk'
  spec.version = RubyTalk::VERSION
  spec.authors = ['Jonathan Badger']
  spec.summary = 'A Smalltalk-80 style programming environment for Ruby, built on Ruby/Tk.'
  spec.description = 'RubyTalk gives Ruby a Smalltalk-style live environment: a Transcript, Workspaces with ' \
                     'do it / print it / inspect it, a System Browser that redefines classes and methods ' \
                     'while the program runs, a debugger, a change log (changes.rb) replayed at startup, ' \
                     'and a Smalltalk-80 graphics and MVC framework.'
  spec.homepage = 'https://github.com/jhbadger/RubyTalk'
  spec.license = 'MIT'

  # CRuby only: the debugger uses TracePoint and Binding, and source handling uses Ripper and
  # RubyVM::InstructionSequence. Tested on 3.0 and later.
  spec.required_ruby_version = '>= 3.0'

  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*.rb', 'bin/*', 'README.md', 'LICENSE']
  spec.bindir = 'bin'
  spec.executables = ['rubytalk']
  spec.require_paths = ['lib']

  # Needs Tcl/Tk installed first (macOS: brew install tcl-tk). The tests do not need it: they use a
  # recording stand-in for Tk (test/fake/tk.rb), which is why the Gemfile leaves it out.
  spec.add_dependency 'tk'
end
