# frozen_string_literal: true

# Shared setup for the headless tests (test_core_*.rb): a fresh Transcript and a temporary
# folder with its own changes.rb for every test.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'timeout'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rubytalk'

# A documented class used by the class-comment tests.
# It has a second line.
class RtDocumented
end
class CoreCase < Minitest::Test
  def setup
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk')
    @changes = RubyTalk::ChangeSet.new(File.join(@dir, 'changes.rb'))
    RubyTalk.changes = @changes
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # A fixture whose source we extract below.
  # Documented method.
  def fixture_method(a, b = 2)
    a + b
  end

  def accept(source, klass: nil, side: :instance)
    RubyTalk::Compiler.accept(source, klass: klass, side: side, changes: @changes)
  end

  def make_class(name, parent = Object, &body)
    Object.const_set(name, Class.new(parent, &body))
  end

  def drop_classes(*names)
    names.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end
end
