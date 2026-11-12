# frozen_string_literal: true

# Versions of class definitions and class comments (not just methods).
#   ruby test/test_class_versions.rb

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'rubytalk'
require 'rubytalk/gui'

# A documented library-style class, for the comment tests.
# Original comment.
class RtCvLib
end

class ClassVersionsTest < Minitest::Test
  include RubyTalk

  def setup
    Transcript.clear
    @saved_home = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    @dir = Dir.mktmpdir('rubytalk-cv')
    ENV['HOME'] = @dir
    ENV['XDG_CONFIG_HOME'] = nil
    @changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
    RubyTalk.changes = @changes
    GUI.reset_layout_state
  end

  def teardown
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = @saved_home
    FileUtils.remove_entry(@dir)
    %i[RtCv].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def accept(source, **options)
    Compiler.accept(source, changes: @changes, **options)
  end

  def versions(klass = RtCv)
    Reflection.versions(klass, :instance, nil, @changes)
  end

  # --- created classes -------------------------------------------------------------

  def test_a_new_class_has_one_version_and_redefining_it_adds_history
    accept("# One.\nclass RtCv\n  attr_reader :a\nend\n")
    assert_equal [:current], versions.map(&:kind)

    accept("# Two.\nclass RtCv\n  attr_reader :a, :b\nend\n")
    list = versions
    assert_equal %i[current previous], list.map(&:kind)
    assert_match(/Two\./, list[0].source)
    assert_match(/One\./, list[1].source)
    assert_match(/\(4 lines\)/, list[1].label) # comment + class, attr_reader, end
  end

  def test_nothing_is_recorded_when_the_class_is_accepted_unchanged
    accept("class RtCv\nend\n")
    accept("class RtCv\nend\n")
    assert_equal [:current], versions.map(&:kind)
  end

  def test_reverting_a_class_definition_keeps_the_replaced_one
    accept("# One.\nclass RtCv\nend\n")
    accept("# Two.\nclass RtCv\nend\n")
    old = versions.last
    outcome = Compiler.revert(RtCv, :instance, nil, old, @changes)
    assert outcome.ok, outcome.message
    assert_match(/One\./, @changes.class_entry('RtCv').source)
    assert_equal %w[One. Two. One.], versions.map { |v| v.source[/(One|Two)\./] }, 'the replaced Two is kept, so the revert can be undone'
    assert_equal %i[current previous previous], versions.map(&:kind)
  end

  def test_method_versions_are_unaffected_by_class_history
    accept("class RtCv\nend\n")
    accept("def m; 1; end\n", klass: RtCv)
    accept("def m; 2; end\n", klass: RtCv)
    accept("# note\nclass RtCv\nend\n")
    assert_equal %i[current previous], Reflection.versions(RtCv, :instance, 'm', @changes).map(&:kind)
    assert_equal 1, Reflection.versions(RtCv, :instance, 'm', @changes).count { |v| v.kind == :previous }
    assert_equal 2, versions.size
  end

  def test_class_history_is_written_and_survives_a_restart
    accept("# One.\nclass RtCv\nend\n")
    accept("# Two.\nclass RtCv\nend\n")
    @changes.save!
    history = File.read(File.join(@dir, 'changes.history'))
    assert_includes history, 'kind=class target=RtCv'
    fresh = ChangeSet.new(File.join(@dir, 'changes.rb'))
    fresh.load!
    assert_equal 1, fresh.class_versions('RtCv').size
    assert_match(/One\./, fresh.class_versions('RtCv').first.source)
  end

  def test_removing_a_class_archives_its_definition
    accept("# One.\nclass RtCv\nend\n")
    Compiler.remove_class(RtCv, @changes)
    assert_match(/One\./, @changes.class_versions('RtCv').first.source)
  end

  # --- comments on classes that already existed -------------------------------------

  def test_comment_edits_on_a_library_class_have_versions_and_an_original
    assert_empty versions(RtCvLib).reject { |v| v.kind == :original }
    accept("# First words.\n#{Reflection.class_template(RtCvLib)}")
    accept("# Second words.\n#{Reflection.class_template(RtCvLib)}")
    list = versions(RtCvLib)
    assert_equal %i[current previous original], list.map(&:kind)
    assert_match(/Second words/, list[0].source)
    assert_match(/First words/, list[1].source)
    assert_match(/Original comment\./, list[2].source)
  end

  def test_reverting_to_the_original_comment_removes_the_entry
    accept("# Mine.\n#{Reflection.class_template(RtCvLib)}")
    original = versions(RtCvLib).find { |v| v.kind == :original }
    assert Compiler.revert(RtCvLib, :instance, nil, original, @changes).ok
    assert_nil @changes.open_entry('RtCvLib', 'comment')
    assert_match(/Original comment\./, Reflection.class_definition(RtCvLib))
    assert_match(/Mine\./, @changes.class_versions('RtCvLib').first.source, 'and your comment stays in the history')
  end

  # --- the window ----------------------------------------------------------------------

  def test_versions_window_for_a_class_and_the_browser_menu
    accept("# One.\nclass RtCv\nend\n")
    accept("# Two.\nclass RtCv\nend\n")
    browser = GUI::Browser.open(RtCv)
    assert_includes browser.instance_variable_get(:@classes).instance_variable_get(:@menu_items).map(&:first),
                    'Versions of this class...'
    browser.send(:show_class_versions)
    window = GUI.windows.last
    assert_instance_of GUI::VersionsWindow, window
    list = window.instance_variable_get(:@list)
    assert_equal 2, list.box.items.size
    list.box.click(1)
    assert_match(/One\./, window.code.contents)
    window.send(:revert)
    assert_match(/One\./, browser.code.contents, 'the browser shows the reverted definition')
    assert_match(/One\./, @changes.class_entry('RtCv').source)
  end

  def test_versions_window_with_no_history_says_so
    GUI::Browser.open(String).send(:show_class_versions)
    window = GUI.windows.last
    assert_match(/No earlier versions of String \(class definition\)/, window.code.contents)
  end
end
