# frozen_string_literal: true

# Source, Accept (Compiler), changes.rb, Preferences and autosave.
#   ruby test/test_core_compiler.rb

require_relative 'support/core_case'

class CoreCompilerTest < CoreCase
  def with_home(home)
    saved = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    ENV['HOME'] = home
    ENV['XDG_CONFIG_HOME'] = nil
    yield
  ensure
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = saved
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


  def test_method_source_extraction
    source = RubyTalk::Source.method_source(method(:fixture_method))
    assert_includes source, '# Documented method.'
    assert_match(/^def fixture_method\(a, b = 2\)\n  a \+ b\nend\n\z/, source)
    assert_nil RubyTalk::Source.method_source(1.method(:+)) # C method
  end

  # --- Compiler / ChangeSet --------------------------------------------


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
    Object.const_set(:RtLib, Class.new) unless defined?(RtLib)
    accept("class RtShape\n  def area; 0; end\nend\n")
    accept("class RtSquare < RtShape\n  def initialize(s); @s = s; end\nend\n")
    accept("def area\n  @s * @s\nend\n", klass: RtSquare)
    accept("def make(s)\n  new(s)\nend\n", klass: RtSquare, side: :class)
    accept("def rt_twice\n  self * 2\nend\n", klass: Integer)
    # Removing a method that already existed (a library method) is logged so it persists.
    RtLib.class_eval { def old; :old; end }
    RubyTalk::Compiler.remove_method(RtLib, :instance, 'old', @changes)
    refute RtLib.method_defined?(:old)
    assert @changes.dirty?

    path = @changes.save!
    assert_equal File.join(@dir, 'changes.rb'), path
    refute @changes.dirty?
    text = File.read(path)
    assert_includes text, '#!rubytalk kind=class target=RtSquare created=true'
    assert_includes text, '#!rubytalk kind=method target=RtSquare side=class key=make'
    assert_includes text, '#!rubytalk kind=remove_method target=RtLib side=instance key=old'

    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      class RtLib; def old; :old; end; end
      RubyTalk.setup(#{@dir.inspect})
      puts RtSquare.make(4).area
      puts 5.rt_twice
      puts RtLib.new.respond_to?(:old)
      puts RubyTalk.changes.user_defined?('RtSquare')
      puts RubyTalk.changes.dirty?
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal %w[16 10 false true false], out.lines.map(&:strip).last(5)
  ensure
    %i[RtSquare RtShape RtLib].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
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
    removed = RtGone # keep it alive: its name survives remove_const while referenced
    RubyTalk::Compiler.remove_class(RtGone, @changes)
    refute defined?(RtGone)
    refute_includes RubyTalk::Reflection.all_modules, removed, 'a removed class is no longer listed'
    refute(RubyTalk::Reflection.hierarchy(Object).any? { |row| row.klass.equal?(removed) })
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


  def test_preferences_default_and_remembered_directory
    with_home(@dir) do
      assert_equal @dir, RubyTalk::Preferences.last_directory, 'the home directory the first time'

      mine = File.join(@dir, 'my image')
      FileUtils.mkdir_p(mine)
      RubyTalk::Preferences.remember_directory(mine)
      assert_equal mine, RubyTalk::Preferences.last_directory
      assert File.file?(RubyTalk::Preferences.last_directory_file)

      FileUtils.remove_entry(mine)
      assert_equal @dir, RubyTalk::Preferences.last_directory, 'a vanished folder falls back to home'
    end
  end

  def test_restart_in_saves_remembers_and_replaces_the_process
    with_home(@dir) do
      target = File.join(@dir, 'next')
      FileUtils.mkdir_p(target)
      accept("class RtRestart\nend\n") # autosave is off here, so this is unsaved
      assert @changes.dirty?
      saved_script = RubyTalk.script_path
      RubyTalk.script_path = '/somewhere/bin/rubytalk'
      command = nil
      RubyTalk.stub(:replace_process, ->(*argv) { command = argv }) { RubyTalk.restart_in(target) }
      assert_equal [RbConfig.ruby, '/somewhere/bin/rubytalk', '--dir', target], command
      assert File.file?(File.join(@dir, 'changes.rb')), 'changes were saved before restarting'
      assert_equal target, RubyTalk::Preferences.last_directory
    ensure
      RubyTalk.script_path = saved_script
      Object.send(:remove_const, :RtRestart) if defined?(RtRestart)
    end
  end

  def test_restart_in_really_execs_the_new_command
    target = File.join(@dir, 'again')
    FileUtils.mkdir_p(target)
    probe = File.join(@dir, 'probe.rb')
    File.write(probe, "puts ARGV.inspect\n")
    script = <<~RUBY
      ENV['HOME'] = #{@dir.inspect}
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      RubyTalk.script_path = #{probe.inspect}
      RubyTalk.setup(#{@dir.inspect})
      RubyTalk.restart_in(#{target.inspect})
      puts 'not reached'
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal ['--dir', target].inspect, out.lines.last.strip
    refute_match(/not reached/, out)
  end

  def test_layout_round_trip_merge_and_bad_lines
    with_home(@dir) do
      assert_empty RubyTalk::Preferences.layout
      saved = RubyTalk::Preferences.save_layout(browser: '900x600+80+90', 'workspace' => '500x400-10+20')
      assert_equal({ 'browser' => '900x600+80+90', 'workspace' => '500x400-10+20' }, saved)

      RubyTalk::Preferences.save_layout(browser: '800x500+0+0', bad: 'nonsense', worse: '10x10')
      assert_equal({ 'browser' => '800x500+0+0', 'workspace' => '500x400-10+20' }, RubyTalk::Preferences.layout,
                   'a new value replaces the old, other kinds are kept, invalid geometries are dropped')

      File.write(RubyTalk::Preferences.layout_file, "browser 1x1+1+1\njunk\nno geometry\ninspector abc\ntests 7x8+9+10\n")
      assert_equal({ 'browser' => '1x1+1+1', 'tests' => '7x8+9+10' }, RubyTalk::Preferences.layout)
    end
  end

  def test_layout_never_raises_when_unwritable
    with_home('/nonexistent-home-for-rubytalk') do
      assert_nil RubyTalk::Preferences.save_layout(browser: '1x1+1+1')
      assert_empty RubyTalk::Preferences.layout
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
    assert_equal :removed, RubyTalk::Compiler.remove_method(RtAuto, :instance, 'a', @changes)
    refute_includes File.read(path), 'key=a', 'a method you created is simply forgotten'
    assert_includes File.read(File.join(@dir, 'changes.history')), 'key=a', 'but its source is kept in the history'
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
end
