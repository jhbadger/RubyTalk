# frozen_string_literal: true

# Protocol categories: `# protocol: name` comments above methods.
#   ruby test/test_protocols.rb

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'rubytalk'
require 'rubytalk/gui'

# A class written the ordinary way, in a file, with some methods filed under protocols.
class RtPrFile
  # protocol: accessing
  def name
    @name
  end

  # Sets the name.
  # protocol: accessing
  def name=(value)
    @name = value
  end

  # PROTOCOL:   testing   things
  def named?
    !@name.nil?
  end

  def plain
    # protocol: not-a-protocol-here (it is in the body, not above the def)
    1
  end

  def self.build
    new
  end
end

class ProtocolsTest < Minitest::Test
  include RubyTalk

  def setup
    Transcript.clear
    @saved_home = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    @dir = Dir.mktmpdir('rubytalk-proto')
    ENV['HOME'] = @dir
    ENV['XDG_CONFIG_HOME'] = nil
    @changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
    RubyTalk.changes = @changes
    GUI.reset_layout_state
  end

  def teardown
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = @saved_home
    FileUtils.remove_entry(@dir)
    %i[RtPr RtPrLoaded].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def accept(source, **options)
    Compiler.accept(source, changes: @changes, **options)
  end

  def labels(klass, side = :instance, inherited = false)
    Reflection.protocol_list(klass, side, inherited, @changes).map(&:first)
  end

  # --- reading the comment ---------------------------------------------------------------

  def test_protocol_of_reads_the_comment_above_the_def
    assert_equal 'accessing', Source.protocol_of("# protocol: accessing\ndef a; end\n")
    assert_equal 'testing things', Source.protocol_of("# note\n# PROTOCOL:   testing   things  \n\ndef a; end\n")
    assert_equal 'x', Source.protocol_of("\n\n# protocol: x\ndef a; end\n"), 'blank lines first are fine'
  end

  def test_protocol_of_ignores_anything_that_is_not_a_leading_comment
    assert_nil Source.protocol_of("def a\n  # protocol: no\nend\n")
    assert_nil Source.protocol_of("def a; end\n# protocol: no\n")
    assert_nil Source.protocol_of("# protocol:\ndef a; end\n"), 'a name is required'
    assert_nil Source.protocol_of("# just a comment\ndef a; end\n")
    assert_nil Source.protocol_of('')
  end

  # --- classes written in files ---------------------------------------------------------------

  def test_protocols_come_from_the_comments_in_the_source_file
    assert_equal ['-- all --', 'accessing', 'testing things', 'as yet unclassified', 'public', 'protected', 'private'],
                 labels(RtPrFile)
    assert_equal %i[name name=], Reflection.methods_for(RtPrFile, :instance, 'accessing', false, @changes)
    assert_equal %i[named?], Reflection.methods_for(RtPrFile, :instance, 'testing things', false, @changes)
    assert_equal %i[plain], Reflection.methods_for(RtPrFile, :instance, :unclassified, false, @changes)
    assert_equal 'accessing', Reflection.method_protocol(RtPrFile, :instance, :name=, @changes), 'a comment line may sit between'
  end

  def test_the_class_side_has_its_own_protocols
    assert_equal ['-- all --', 'public', 'protected', 'private'], labels(RtPrFile, :class),
                 'no protocol comments there: no extra entries and no "unclassified"'
    assert_equal %i[build], Reflection.methods_for(RtPrFile, :class, :public, false, @changes).first(1)
  end

  def test_a_class_with_no_protocol_comments_has_the_plain_list
    assert_equal Reflection::PROTOCOLS.map(&:first), labels(String)
    assert_equal Reflection::PROTOCOLS.map(&:first), labels(Object, :instance, true)
  end

  def test_the_unclassified_entry_appears_only_when_some_methods_have_a_protocol_and_some_do_not
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; end\n", klass: RtPr)
    refute_includes labels(RtPr), Reflection::UNCLASSIFIED, 'every method is classified'
    accept("def b; end\n", klass: RtPr)
    assert_includes labels(RtPr), Reflection::UNCLASSIFIED
  end

  def test_files_without_the_word_protocol_are_never_kept_in_the_cache
    plain = File.join(@dir, 'plain.rb')
    File.write(plain, "class RtPrLoaded\n  def a; end\nend\n")
    load plain
    assert_nil Reflection.file_info(plain)
    assert_equal Reflection::PROTOCOLS.map(&:first), labels(RtPrLoaded)

    File.write(plain, "class RtPrLoaded\n  # protocol: later\n  def a; end\nend\n")
    File.utime(Time.now + 5, Time.now + 5, plain) # a changed file is noticed
    assert_equal 4, Reflection.file_info(plain).lines.size
  end

  def test_unreadable_files_are_just_skipped
    assert_nil Reflection.file_info(File.join(@dir, 'missing.rb'))
  end

  # --- classes changed in RubyTalk ----------------------------------------------------------

  def test_methods_accepted_with_a_protocol_comment_are_filed_under_it
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; 1; end\n", klass: RtPr)
    accept("# protocol: testing\ndef b?; true; end\n", klass: RtPr)
    assert_equal ['-- all --', 'accessing', 'testing', 'public', 'protected', 'private'], labels(RtPr)
    assert_equal %i[a], Reflection.methods_for(RtPr, :instance, 'accessing', false, @changes)

    accept("# protocol: testing\ndef a; 2; end\n", klass: RtPr) # moved by editing the comment
    assert_equal %i[a b?], Reflection.methods_for(RtPr, :instance, 'testing', false, @changes)
    assert_equal ['-- all --', 'testing', 'public', 'protected', 'private'], labels(RtPr), 'an empty protocol disappears'
    assert_equal 2, RtPr.new.a, 'the comment does not change what the method does'
  end

  def test_a_replayed_changes_file_keeps_protocols
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; 1; end\n", klass: RtPr)
    @changes.save!
    Object.send(:remove_const, :RtPr)
    fresh = ChangeSet.new(File.join(@dir, 'changes.rb'))
    RubyTalk.changes = fresh
    fresh.load!
    assert_equal ['-- all --', 'accessing', 'public', 'protected', 'private'], Reflection.protocol_list(RtPr, :instance, false, fresh).map(&:first)
  end

  def test_method_template_for_a_protocol_of_your_own
    assert_equal "def method_name(arg)\n  # comment\n  \nend\n", Reflection.method_template
    assert_equal Reflection.method_template, Reflection.method_template(:public)
    assert_equal Reflection.method_template, Reflection.method_template(:unclassified)
    assert_equal "# protocol: accessing\n#{Reflection.method_template}", Reflection.method_template('accessing')
  end

  # --- the Browser ---------------------------------------------------------------------------

  def items(browser)
    browser.instance_variable_get(:@protocols).box.items
  end

  def protocols_pane(browser)
    browser.instance_variable_get(:@protocols)
  end

  def test_browser_lists_protocols_and_filters_methods_by_them
    browser = GUI::Browser.open(RtPrFile)
    assert_equal ['-- all --', 'accessing', 'testing things', 'as yet unclassified', 'public', 'protected', 'private'], items(browser)

    protocols_pane(browser).box.click(1) # accessing
    methods = browser.instance_variable_get(:@methods)
    assert_equal %i[name name=], methods.instance_variable_get(:@values)

    protocols_pane(browser).box.click(3) # as yet unclassified
    assert_equal %i[plain], methods.instance_variable_get(:@values)
  end

  def test_a_new_method_in_a_protocol_starts_with_its_comment_and_lands_there
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; 1; end\n", klass: RtPr)
    browser = GUI::Browser.open(RtPr)
    protocols_pane(browser).box.click(items(browser).index('accessing'))
    assert_equal "# protocol: accessing\ndef method_name(arg)\n  # comment\n  \nend\n", browser.code.contents
    assert_match(/New instance method in protocol accessing on RtPr/, browser.instance_variable_get(:@status).options[:text])

    browser.code.set_contents("# protocol: accessing\ndef b; 2; end\n")
    browser.code.accept
    assert_equal 2, RtPr.new.b
    methods = browser.instance_variable_get(:@methods).instance_variable_get(:@values)
    assert_includes methods, :b, 'the new method shows up in the protocol it was made in'
  end

  def test_accepting_a_method_with_a_new_protocol_adds_it_to_the_list
    accept("class RtPr\nend\n")
    browser = GUI::Browser.open(RtPr)
    assert_equal %w[-- all -- public protected private].join(' '), items(browser).join(' ')
    protocols_pane(browser).box.click(0)
    browser.code.set_contents("# protocol: brand new\ndef c; 3; end\n")
    browser.code.accept
    assert_includes items(browser), 'brand new'
  end

  def test_switching_sides_and_removing_a_method_refresh_the_list
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; 1; end\n", klass: RtPr)
    accept("# protocol: building\ndef self.make; new; end\n", klass: RtPr)
    browser = GUI::Browser.open(RtPr)
    assert_includes items(browser), 'accessing'
    refute_includes items(browser), 'building'

    browser.instance_variable_get(:@side_var).value = +'class'
    browser.send(:side_changed)
    assert_includes items(browser), 'building'
    refute_includes items(browser), 'accessing'

    browser.instance_variable_get(:@side_var).value = +'instance'
    browser.send(:side_changed)
    protocols_pane(browser).box.click(items(browser).index('accessing'))
    methods = browser.instance_variable_get(:@methods)
    methods.box.click(0)
    GUI.stub(:confirm, true) { browser.send(:remove_method) }
    refute_includes items(browser), 'accessing', 'the last method of a protocol takes the protocol with it'
  end

  def test_show_inherited_includes_protocols_of_superclasses
    accept("class RtPr\nend\n")
    accept("# protocol: accessing\ndef a; 1; end\n", klass: RtPr)
    accept("class RtPrKid < RtPr\nend\n")
    browser = GUI::Browser.open(RtPrKid)
    refute_includes items(browser), 'accessing'
    browser.instance_variable_get(:@inherited_var).value = 1
    browser.send(:inherited_changed)
    assert_includes items(browser), 'accessing'
  ensure
    Object.send(:remove_const, :RtPrKid) if Object.const_defined?(:RtPrKid)
  end
end
