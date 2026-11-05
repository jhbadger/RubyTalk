# frozen_string_literal: true

# Headless tests for everything except the Tk windows.
#   ruby test/test_core.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rubytalk'

class CoreTest < Minitest::Test
  def setup
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk')
    @changes = RubyTalk::ChangeSet.new(File.join(@dir, 'changes.rb'))
    RubyTalk.changes = @changes
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- Transcript -------------------------------------------------------

  def test_transcript_smalltalk_protocol
    Transcript.show('a').tab.show('b').space.show_cr('c')
    Transcript.display(42).cr
    Transcript.print_string('x').cr
    assert_equal "a\tb c\n42\n\"x\"\n", Transcript.buffer
  end

  def test_transcript_listener_and_clear
    seen = []
    Transcript.add_listener { |chunk| seen << chunk }
    Transcript.show('hi')
    Transcript.clear
    assert_equal ['hi', :clear], seen
    assert_equal '', Transcript.buffer
  end

  def test_transcript_is_a_stdout_replacement
    result = RubyTalk::Evaluator.evaluate("puts 'out'; print 1, 2; p :sym; $stderr.puts 'err'; 7", binding)
    assert result.ok
    assert_equal 7, result.value
    assert_equal "out\n12:sym\nerr\n", Transcript.buffer
    refute_same Transcript, $stdout
  end

  # --- Evaluator --------------------------------------------------------

  def test_workspace_binding_keeps_temporaries
    ws = RubyTalk::Evaluator.new_binding
    RubyTalk::Evaluator.evaluate('x = 20', ws)
    assert_equal 22, RubyTalk::Evaluator.evaluate('x + 2', ws).value
    other = RubyTalk::Evaluator.new_binding
    refute RubyTalk::Evaluator.evaluate('x', other).ok
  end

  def test_errors_are_reported_not_raised
    result = RubyTalk::Evaluator.evaluate('1 / 0', RubyTalk::Evaluator.new_binding)
    refute result.ok
    assert_kind_of ZeroDivisionError, result.error
    assert_match(/ZeroDivisionError: divided by 0/, Transcript.buffer)
    syntax = RubyTalk::Evaluator.evaluate('def (', RubyTalk::Evaluator.new_binding)
    refute syntax.ok
    assert_kind_of SyntaxError, syntax.error
  end

  def test_evaluate_in_receiver
    assert_equal 3, RubyTalk::Evaluator.evaluate_in('size', [1, 2, 3]).value
    assert_equal 'abc', RubyTalk::Evaluator.evaluate_in('self', 'abc').value
  end

  # --- Source -----------------------------------------------------------

  def test_split_statements_and_describe
    text = <<~RUBY
      # adds
      def add(a, b)
        a + b
      end

      def self.make; new; end
      attr_accessor :x
      def [](i) = i
    RUBY
    parts = RubyTalk::Source.split_statements(text)
    assert_equal 4, parts.size
    assert_match(/\A# adds\ndef add/, parts[0])
    kinds = parts.map { |s| RubyTalk::Source.describe(s) }
    assert_equal %i[def defs other def], kinds.map(&:kind)
    assert_equal ['add', 'make', nil, '[]'], kinds.map(&:name)
  end

  def test_describe_classes
    assert_equal [:class, 'Foo'], RubyTalk::Source.describe("class Foo < Object\nend\n").to_a
    assert_equal [:class, 'A::B'], RubyTalk::Source.describe("class A::B\nend\n").to_a
    assert_equal [:module, 'M'], RubyTalk::Source.describe("module M\nend\n").to_a
  end

  def test_syntax_error
    assert_nil RubyTalk::Source.syntax_error('def a; end')
    assert_kind_of SyntaxError, RubyTalk::Source.syntax_error('def a')
  end

  # A fixture whose source we extract below.
  # Documented method.
  def fixture_method(a, b = 2)
    a + b
  end

  def test_method_source_extraction
    source = RubyTalk::Source.method_source(method(:fixture_method))
    assert_includes source, '# Documented method.'
    assert_match(/^def fixture_method\(a, b = 2\)\n  a \+ b\nend\n\z/, source)
    assert_nil RubyTalk::Source.method_source(1.method(:+)) # C method
  end

  # --- Compiler / ChangeSet --------------------------------------------

  def accept(source, klass: nil, side: :instance)
    RubyTalk::Compiler.accept(source, klass: klass, side: side, changes: @changes)
  end

  def test_create_class_and_methods
    out = accept("class RtPoint < Object\n  attr_reader :x\nend\n")
    assert out.ok, out.message
    klass = RtPoint
    assert_equal klass, out.klass
    assert @changes.user_defined?('RtPoint')

    assert accept("def initialize(x)\n  @x = x\nend\n", klass: klass).ok
    assert accept("def double\n  @x * 2\nend\n", klass: klass).ok
    assert accept("def origin\n  new(0)\nend\n", klass: klass, side: :class).ok
    assert accept("def self.unit\n  new(1)\nend\n", klass: klass).ok
    assert_equal 6, RtPoint.new(3).double
    assert_equal 0, RtPoint.origin.x
    assert_equal 1, RtPoint.unit.x

    entry = @changes.find_method('RtPoint', :class, 'unit')
    assert entry, 'def self.x is logged as a class-side method'
    assert_equal 'double', @changes.find_method('RtPoint', :instance, 'double').key
  ensure
    Object.send(:remove_const, :RtPoint) if defined?(RtPoint)
  end

  def test_redefining_a_method_replaces_the_change
    accept("class RtRedef\nend\n")
    accept("def v; 1; end\n", klass: RtRedef)
    accept("def v; 2; end\n", klass: RtRedef)
    assert_equal 2, RtRedef.new.v
    assert_equal 1, @changes.entries.count { |e| e.kind == :method }
    assert_includes @changes.find_method('RtRedef', :instance, 'v').source, '2'
  ensure
    Object.send(:remove_const, :RtRedef) if defined?(RtRedef)
  end

  def test_extend_builtin_class
    out = accept("def rt_shout\n  upcase + '!'\nend\n", klass: String)
    assert out.ok, out.message
    assert_equal 'HI!', 'hi'.rt_shout
    assert_equal :method, @changes.entries.last.kind
    refute @changes.user_defined?('String')
  ensure
    String.send(:remove_method, :rt_shout) if String.method_defined?(:rt_shout)
  end

  def test_accept_errors_do_not_log
    refute accept('def broken', klass: String).ok
    refute accept("def ok; end\n").ok # no class selected
    out = accept("def boom\n  1\nend\nraise 'x'\n", klass: Object)
    refute out.ok
    assert_match(/RuntimeError: x/, out.message)
  ensure
    Object.send(:remove_method, :boom) if Object.method_defined?(:boom)
  end

  def test_roundtrip_through_file_in_fresh_process
    accept("class RtShape\n  def area; 0; end\nend\n")
    accept("class RtSquare < RtShape\n  def initialize(s); @s = s; end\nend\n")
    accept("def area\n  @s * @s\nend\n", klass: RtSquare)
    accept("def make(s)\n  new(s)\nend\n", klass: RtSquare, side: :class)
    accept("def rt_twice\n  self * 2\nend\n", klass: Integer)
    accept("def gone; end\n", klass: RtShape)
    RubyTalk::Compiler.remove_method(RtShape, :instance, 'gone', @changes)
    assert @changes.dirty?

    path = @changes.save!
    assert_equal File.join(@dir, 'changes.rb'), path
    refute @changes.dirty?
    text = File.read(path)
    assert_includes text, '#!rubytalk kind=class target=RtSquare created=true'
    assert_includes text, '#!rubytalk kind=method target=RtSquare side=class key=make'
    assert_includes text, '#!rubytalk kind=remove_method target=RtShape side=instance key=gone'

    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      RubyTalk.setup(#{@dir.inspect})
      puts RtSquare.make(4).area
      puts 5.rt_twice
      puts RtShape.new.respond_to?(:gone)
      puts RubyTalk.changes.user_defined?('RtSquare')
      puts RubyTalk.changes.dirty?
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal %w[16 10 false true false], out.lines.map(&:strip).last(5)
  ensure
    %i[RtSquare RtShape].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    Integer.send(:remove_method, :rt_twice) if Integer.method_defined?(:rt_twice)
  end

  def test_failed_chunk_is_reported_and_kept
    File.write(File.join(@dir, 'changes.rb'), <<~TEXT)
      #!rubytalk kind=method target=NoSuchClass side=instance key=foo
      def foo; end

      #!rubytalk kind=class target=RtOk created=true
      class RtOk; def hi; :hi; end; end
    TEXT
    changes = RubyTalk::ChangeSet.new(File.join(@dir, 'changes.rb'))
    assert_equal 1, changes.load!
    assert_equal 2, changes.entries.size
    assert changes.entries.first.failed
    assert_equal :hi, RtOk.new.hi
    assert_match(/could not apply method NoSuchClass#foo/, Transcript.buffer)
    refute changes.dirty?
    assert_nil changes.save!, 'unchanged session writes nothing'
  ensure
    Object.send(:remove_const, :RtOk) if defined?(RtOk)
  end

  def test_save_makes_backup_and_skips_when_clean
    accept("class RtB\nend\n")
    @changes.save!
    accept("def a; end\n", klass: RtB)
    @changes.save!
    assert File.exist?(File.join(@dir, 'changes.rb.bak'))
    assert_nil @changes.save!
  ensure
    Object.send(:remove_const, :RtB) if defined?(RtB)
  end

  def test_remove_class_only_for_user_classes
    accept("class RtGone\nend\n")
    RubyTalk::Compiler.remove_class(RtGone, @changes)
    refute defined?(RtGone)
    assert_empty @changes.entries
    assert_raises(RubyTalk::Compiler::Error) { RubyTalk::Compiler.remove_class(String, @changes) }
  end

  def test_reopen_builtin_with_unmodified_template_logs_nothing
    template = RubyTalk::Reflection.class_definition(Comparable)
    out = accept(template)
    assert out.ok, out.message
    assert_empty @changes.entries
  end

  # --- Preferences (folder chooser memory) --------------------------------

  def with_home(home)
    saved = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    ENV['HOME'] = home
    ENV['XDG_CONFIG_HOME'] = nil
    yield
  ensure
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = saved
  end

  def test_preferences_default_and_remembered_directory
    with_home(@dir) do
      assert_equal @dir, RubyTalk::Preferences.last_directory, 'home when ~/RubyTalk does not exist'
      FileUtils.mkdir_p(File.join(@dir, 'RubyTalk'))
      assert_equal File.join(@dir, 'RubyTalk'), RubyTalk::Preferences.last_directory

      mine = File.join(@dir, 'my image')
      FileUtils.mkdir_p(mine)
      RubyTalk::Preferences.remember_directory(mine)
      assert_equal mine, RubyTalk::Preferences.last_directory
      assert File.file?(RubyTalk::Preferences.last_directory_file)

      FileUtils.remove_entry(mine)
      assert_equal File.join(@dir, 'RubyTalk'), RubyTalk::Preferences.last_directory, 'a vanished folder is not offered'
    end
  end

  def test_preferences_never_raise_when_unwritable
    with_home('/nonexistent-home-for-rubytalk') do
      assert_nil RubyTalk::Preferences.remember_directory('/tmp')
      assert_equal '/nonexistent-home-for-rubytalk', RubyTalk::Preferences.last_directory
    end
  end

  # --- Autosave ---------------------------------------------------------

  def test_autosave_writes_each_change_and_keeps_one_startup_backup
    path = File.join(@dir, 'changes.rb')
    File.write(path, "# old\n")
    @changes.autosave = true
    accept("class RtAuto\nend\n")
    assert_includes File.read(path), 'target=RtAuto'
    assert_equal "# old\n", File.read("#{path}.bak")
    accept("def a; end\n", klass: RtAuto)
    assert_includes File.read(path), 'key=a'
    assert_equal "# old\n", File.read("#{path}.bak"), 'backup stays the file as it was at startup'
    refute @changes.dirty?
    RubyTalk::Compiler.remove_method(RtAuto, :instance, 'a', @changes)
    assert_includes File.read(path), 'kind=remove_method'
  ensure
    Object.send(:remove_const, :RtAuto) if defined?(RtAuto)
  end

  def test_autosave_failure_does_not_break_accept
    changes = RubyTalk::ChangeSet.new('/nonexistent-dir-for-rubytalk/changes.rb')
    changes.autosave = true
    out = RubyTalk::Compiler.accept("class RtNoDisk\nend\n", changes: changes)
    assert out.ok, out.message
    refute changes.autosave
    assert changes.dirty?, 'still pending for the exit save'
    assert_match(/autosave disabled/, Transcript.buffer)
  ensure
    Object.send(:remove_const, :RtNoDisk) if defined?(RtNoDisk)
  end

  # --- Implementors / senders ------------------------------------------

  def fixture_sender
    rt_unique_selector_zzz
  end

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
    assert_includes RubyTalk::Search.implementors('fixture_method').map(&:label), 'CoreTest#fixture_method'
    accept("class RtImpl\n  def self.rt_cls_impl; end\nend\n")
    assert_includes RubyTalk::Search.implementors('rt_cls_impl').map(&:label), 'RtImpl.rt_cls_impl'
    assert_empty RubyTalk::Search.implementors('no_such_method_anywhere_zzz')
  ensure
    Object.send(:remove_const, :RtImpl) if defined?(RtImpl)
  end

  def test_senders_in_files_and_in_changes
    labels = RubyTalk::Search.senders('rt_unique_selector_zzz', @changes).map(&:label)
    assert_equal ['CoreTest#fixture_sender'], labels

    accept("class RtSend\n  def go\n    rt_unique_selector_zzz\n  end\nend\n")
    accept("def again\n  rt_unique_selector_zzz\nend\n", klass: RtSend, side: :class)
    accept("attr_accessor :rt_unique_selector_zzz\n", klass: RtSend) # a body statement: mentions it as a symbol
    hits = RubyTalk::Search.senders('rt_unique_selector_zzz', @changes)
    labels = hits.map(&:label)
    assert_includes labels, 'RtSend (class body)'
    assert_includes labels, 'RtSend.again'
    assert_includes labels, 'CoreTest#fixture_sender'
    assert_empty RubyTalk::Search.senders('no_such_selector_anywhere_zzz', @changes)
  ensure
    Object.send(:remove_const, :RtSend) if defined?(RtSend)
  end

  # --- Reflection -------------------------------------------------------

  def test_categories
    accept("class RtCat\nend\n")
    catalog = RubyTalk::Reflection.catalog(@changes)
    assert_equal 'User-Defined', catalog.names.first
    assert_equal 'All Classes', catalog.names.last
    assert_includes catalog.classes_in('User-Defined'), RtCat
    assert_includes catalog.classes_in('Collections'), Array
    assert_includes catalog.classes_in('Exceptions'), ArgumentError
    assert_includes catalog.classes_in('Modules'), Math unless catalog.classes_in('Numbers').include?(Math)
    assert_includes catalog.classes_in('All Classes'), RtCat
  ensure
    Object.send(:remove_const, :RtCat) if defined?(RtCat)
  end

  def test_methods_for_and_text
    names = RubyTalk::Reflection.methods_for(String, :instance, :public, false)
    assert_includes names, :upcase
    assert_includes RubyTalk::Reflection.methods_for(String, :class, :all, false), :try_convert
    refute_includes RubyTalk::Reflection.methods_for(String, :class, :all, false), :new
    assert_includes RubyTalk::Reflection.methods_for(String, :class, :all, true), :new
    refute_includes RubyTalk::Reflection.methods_for(String, :instance, :private, false), :upcase

    text = RubyTalk::Reflection.method_text(String, :instance, :upcase)
    assert_match(/implemented in C/, text)
    assert_match(/# def upcase\(\*args\)/, text)
    assert_equal RubyTalk::Reflection.method_template, RubyTalk::Reflection.method_text(String, :instance, :nope)
  end

  def test_user_method_text_comes_from_changes
    accept("class RtShow\nend\n")
    accept("# note\ndef hello\n  :hi\nend\n", klass: RtShow)
    text = RubyTalk::Reflection.method_text(RtShow, :instance, :hello)
    assert_equal "# note\ndef hello\n  :hi\nend\n", text
    assert_equal '* hello', RubyTalk::Reflection.method_label(RtShow, :instance, :hello, @changes)
  ensure
    Object.send(:remove_const, :RtShow) if defined?(RtShow)
  end

  def test_class_definition_text
    assert_equal "class Integer < Numeric\n  include Comparable\nend\n".lines.first,
                 RubyTalk::Reflection.class_definition(Integer).lines.first
    assert_equal "module Comparable\nend\n", RubyTalk::Reflection.class_definition(Comparable)
  end

  def test_owner_label_for_class_side
    method = String.method(:new).unbind
    assert_match(/class side|Class/, RubyTalk::Reflection.owner_label(method.owner))
  end
end
