# frozen_string_literal: true

# Implementors / senders, and the Versions of a method.
#   ruby test/test_core_search_versions.rb

require_relative 'support/core_case'

class CoreSearchVersionsTest < CoreCase
  def fixture_sender
    rt_unique_selector_zzz
  end

  # --- Implementors / senders ------------------------------------------


  def test_mentions_ignores_comments_strings_and_definitions
    mentions = ->(code, sel = 'upcase') { RubyTalk::Source.mentions?(code, sel) }
    assert mentions.call("x.upcase")
    assert mentions.call("x.map(&:upcase)")
    assert mentions.call("send(:upcase)")
    refute mentions.call("# upcase\n'upcase'\n\"upcase\"")
    refute mentions.call("def upcase\n  1\nend")
    refute mentions.call("def self.upcase\n  1\nend")
    assert mentions.call("def upcase\n  upcase\nend"), 'a recursive call still counts'
    assert mentions.call("self.name = 1", 'name=')
    refute mentions.call("a[1]", '[]'), 'bracket selectors are not searched'
  end

  def test_implementors
    labels = RubyTalk::Search.implementors('upcase').map(&:label)
    assert_includes labels, 'String#upcase'
    assert_includes labels, 'Symbol#upcase'
    assert_includes RubyTalk::Search.implementors('fixture_method').map(&:label), 'CoreCase#fixture_method'
    accept("class RtImpl\n  def self.rt_cls_impl; end\nend\n")
    assert_includes RubyTalk::Search.implementors('rt_cls_impl').map(&:label), 'RtImpl.rt_cls_impl'
    assert_empty RubyTalk::Search.implementors('no_such_method_anywhere_zzz')
  ensure
    Object.send(:remove_const, :RtImpl) if defined?(RtImpl)
  end

  def test_senders_in_files_and_in_changes
    labels = RubyTalk::Search.senders('rt_unique_selector_zzz', @changes).map(&:label)
    assert_equal ["#{self.class.name}#fixture_sender"], labels

    accept("class RtSend\n  def go\n    rt_unique_selector_zzz\n  end\nend\n")
    accept("def again\n  rt_unique_selector_zzz\nend\n", klass: RtSend, side: :class)
    accept("attr_accessor :rt_unique_selector_zzz\n", klass: RtSend) # a body statement: mentions it as a symbol
    hits = RubyTalk::Search.senders('rt_unique_selector_zzz', @changes)
    labels = hits.map(&:label)
    assert_includes labels, 'RtSend (class body)'
    assert_includes labels, 'RtSend.again'
    assert_includes labels, "#{self.class.name}#fixture_sender"
    assert_empty RubyTalk::Search.senders('no_such_selector_anywhere_zzz', @changes)
  ensure
    Object.send(:remove_const, :RtSend) if defined?(RtSend)
  end

  # --- Versions, history and originals ------------------------------------



  def test_history_keeps_replaced_versions_in_a_file_and_reloads_them
    @changes.autosave = true
    accept("class RtVer\nend\n")
    accept("def v\n  1\nend\n", klass: RtVer)
    accept("def v\n  2\nend\n", klass: RtVer)
    accept("def v\n  2\nend\n", klass: RtVer) # unchanged: nothing new to remember
    accept("def v\n  3\nend\n", klass: RtVer)

    versions = @changes.versions('RtVer', :instance, 'v')
    assert_equal ["def v\n  2\nend\n", "def v\n  1\nend\n"], versions.map(&:source), 'newest first'
    assert(versions.all? { |entry| entry.at.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/) })
    history = File.read(File.join(@dir, 'changes.history'))
    assert_equal 2, history.scan('#!rubytalk kind=method').size

    fresh = RubyTalk::ChangeSet.new(File.join(@dir, 'changes.rb'))
    fresh.load!
    assert_equal 2, fresh.versions('RtVer', :instance, 'v').size, 'history survives a restart'
    assert_equal "def v\n  3\nend\n", fresh.find_method('RtVer', :instance, 'v').source
  ensure
    drop_classes(:RtVer)
  end

  def test_history_is_written_on_save_even_without_autosave
    accept("class RtVer3\nend\n")
    accept("def v; 1; end\n", klass: RtVer3)
    accept("def v; 2; end\n", klass: RtVer3)
    refute File.exist?(File.join(@dir, 'changes.history')), 'nothing written yet'
    @changes.save!
    assert_includes File.read(File.join(@dir, 'changes.history')), 'def v; 1; end'
  ensure
    drop_classes(:RtVer3)
  end

  def test_entries_from_older_files_have_no_timestamp
    entries = RubyTalk::ChangeSet.parse("#!rubytalk kind=method target=X side=instance key=m\ndef m; end\n")
    assert_nil entries.first.at
    assert_equal ' - earlier session', RubyTalk::Reflection.when_label(nil)
  end

  def test_override_of_a_method_can_be_reverted_to_its_original
    make_class(:RtOwn) { def hello = :orig }
    accept("def hello\n  :changed\nend\n", klass: RtOwn)
    assert_equal :changed, RtOwn.new.hello
    versions = RubyTalk::Reflection.versions(RtOwn, :instance, 'hello', @changes)
    assert_equal %i[current original], versions.map(&:kind)
    assert_match(/\ACurrent - \d{4}-\d\d-\d\d \d\d:\d\d\z/, versions.first.label)
    assert_equal 'Original (library)', versions.last.label
    assert_includes versions.last.source, 'hello'

    out = RubyTalk::Compiler.revert(RtOwn, :instance, 'hello', versions.last, @changes)
    assert out.ok, out.message
    assert_equal :orig, RtOwn.new.hello
    assert_nil @changes.find_method('RtOwn', :instance, 'hello')
    assert_equal 1, @changes.versions('RtOwn', :instance, 'hello').size, 'the override is kept in the history'
  ensure
    drop_classes(:RtOwn)
  end

  def test_override_of_an_inherited_method_reverts_by_removing_the_override
    parent = make_class(:RtParent) { def hi = :parent }
    child = make_class(:RtChild, parent)
    accept("def hi\n  :child\nend\n", klass: child)
    assert_equal :child, child.new.hi
    assert_equal :reverted, RubyTalk::Compiler.remove_method(child, :instance, 'hi', @changes)
    assert_equal :parent, child.new.hi
    refute child.method_defined?(:hi, false)
    assert_empty(@changes.entries.reject { |e| e.kind == :class })
  ensure
    drop_classes(:RtChild, :RtParent)
  end

  def test_builtin_c_method_can_be_restored
    string_class = make_class(:RtCStr, String)
    string_class.send(:define_method, :up2, String.instance_method(:upcase)) # an own method with a C body
    accept("def up2\n  :overridden\nend\n", klass: string_class)
    assert_equal :overridden, string_class.new('ab').up2
    versions = RubyTalk::Reflection.versions(string_class, :instance, 'up2', @changes)
    assert_match(/implemented in C/, versions.last.source)
    RubyTalk::Compiler.revert(string_class, :instance, 'up2', versions.last, @changes)
    assert_equal 'AB', string_class.new('ab').up2
  ensure
    drop_classes(:RtCStr)
  end

  def test_restoring_keeps_the_original_visibility
    make_class(:RtVis) { private def secret = :s }
    accept("def secret\n  :changed\nend\n", klass: RtVis)
    RubyTalk::Compiler.remove_method(RtVis, :instance, 'secret', @changes)
    assert RtVis.private_method_defined?(:secret)
    assert_equal :s, RtVis.new.send(:secret)
  ensure
    drop_classes(:RtVis)
  end

  def test_removing_a_method_you_created_is_forgotten_not_logged
    accept("class RtMine\nend\n")
    accept("def mine; end\n", klass: RtMine)
    assert_equal :removed, RubyTalk::Compiler.remove_method(RtMine, :instance, 'mine', @changes)
    refute RtMine.method_defined?(:mine)
    assert_equal [:class], @changes.entries.map(&:kind)
    assert_equal 1, @changes.versions('RtMine', :instance, 'mine').size
  ensure
    drop_classes(:RtMine)
  end

  def test_removing_a_library_method_is_logged_and_recoverable
    make_class(:RtLib2) { def old = :old }
    assert_equal :removed, RubyTalk::Compiler.remove_method(RtLib2, :instance, 'old', @changes)
    refute RtLib2.method_defined?(:old)
    assert_equal [:remove_method], @changes.entries.map(&:kind)
    versions = RubyTalk::Reflection.versions(RtLib2, :instance, 'old', @changes)
    assert_equal [:original], versions.map(&:kind)
    RubyTalk::Compiler.revert(RtLib2, :instance, 'old', versions.first, @changes)
    assert_equal :old, RtLib2.new.old
    assert_empty @changes.entries, 'the logged removal is cleared'
  ensure
    drop_classes(:RtLib2)
  end

  def test_reverting_to_a_previous_version_can_itself_be_reverted
    accept("class RtRev\nend\n")
    accept("def v\n  1\nend\n", klass: RtRev)
    accept("def v\n  2\nend\n", klass: RtRev)
    versions = RubyTalk::Reflection.versions(RtRev, :instance, 'v', @changes)
    assert_equal %i[current previous], versions.map(&:kind)
    assert RubyTalk::Compiler.revert(RtRev, :instance, 'v', versions[1], @changes).ok
    assert_equal 1, RtRev.new.v

    versions = RubyTalk::Reflection.versions(RtRev, :instance, 'v', @changes)
    assert_equal %i[current previous previous], versions.map(&:kind)
    assert_equal [1, 2, 1], versions.map { |v| v.source[/\d/].to_i }
    assert_match(/\A\d{4}-\d\d-\d\d \d\d:\d\d  \(3 lines\)\z/, versions[1].label)
    RubyTalk::Compiler.revert(RtRev, :instance, 'v', versions[1], @changes)
    assert_equal 2, RtRev.new.v
  ensure
    drop_classes(:RtRev)
  end

  def test_revert_to_original_with_nothing_known_fails_cleanly
    version = RubyTalk::Reflection::Version.new(:original, 'Original (library)', '', nil)
    out = RubyTalk::Compiler.revert(String, :instance, 'rt_never_touched', version, @changes)
    refute out.ok
    assert_match(/no original version/, out.message)
  end

  def test_diff
    diff = RubyTalk::Diff
    assert_equal [[' ', 'a'], ['-', 'b'], ['+', 'x'], [' ', 'c'], ['+', 'd']], diff.lines("a\nb\nc\n", "a\nx\nc\nd\n")
    assert_equal "  a\n- b\n+ x\n", diff.unified("a\nb\n", "a\nx\n")
    assert_equal [[' ', 'same']], diff.lines("same\n", "same\n")
    assert_equal [['+', 'new']], diff.lines('', "new\n")
    assert_equal [['-', 'old']], diff.lines("old\n", nil)
    assert_empty diff.lines(nil, nil)
    assert diff.changed?("a\n", "b\n")
    refute diff.changed?("a\n", "a")
    big = (1..600).map(&:to_s).join("\n")
    assert_nil diff.lines(big, big.reverse)
    assert_equal "(too large to compare)\n", diff.unified(big, big.reverse)
  end
end
