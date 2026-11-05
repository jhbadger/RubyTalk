# frozen_string_literal: true

# Headless tests for everything except the Tk windows.
#   ruby test/test_core.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'timeout'
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

  # --- Interruptible evaluation (worker thread + driver) ----------------------

  # Drivers decide what the calling thread does while code runs on the worker.
  class JoinDriver
    def self.wait(worker)
      worker.join
    end
  end

  # Presses Stop (once or more) shortly after the code starts.
  class StopDriver
    class << self
      attr_accessor :presses

      def wait(worker)
        sleep 0.05
        (presses || 1).times do
          RubyTalk::Evaluator.stop
          sleep 0.05
        end
        worker.join
      end
    end
  end

  # Raises Ctrl-C (Interrupt) on the calling thread once, as a terminal would.
  class CtrlCDriver
    class << self
      attr_accessor :raised

      def wait(worker)
        unless raised
          self.raised = true
          sleep 0.05
          raise Interrupt
        end
        worker.join
      end
    end
  end

  class DyingDriver
    def self.wait(_worker)
      sleep 0.05
      raise 'the window system went away'
    end
  end

  def with_driver(driver)
    RubyTalk::Evaluator.driver = driver
    Timeout.timeout(10) { yield }
  ensure
    RubyTalk::Evaluator.driver = nil
    StopDriver.presses = nil
    CtrlCDriver.raised = nil
  end

  def threaded(source)
    RubyTalk::Evaluator.evaluate(source, RubyTalk::Evaluator.new_binding)
  end

  def test_threaded_evaluation_returns_values_output_and_errors
    with_driver(JoinDriver) do
      result = threaded("puts 'from worker'; Thread.current == Thread.main ? :main : :worker")
      assert result.ok
      assert_equal :worker, result.value, 'code runs off the calling thread'
      assert_equal "from worker\n", Transcript.buffer
      assert_kind_of ZeroDivisionError, threaded('1 / 0').error
      assert_kind_of SyntaxError, threaded('def (').error
      refute RubyTalk::Evaluator.busy?
    end
  end

  def test_stop_interrupts_a_runaway_loop_and_runs_ensure_blocks
    with_driver(StopDriver) do
      $rt_ensure_ran = false
      result = threaded("begin; loop {}; ensure; $rt_ensure_ran = true; end")
      refute result.ok
      assert_kind_of RubyTalk::Evaluator::Interrupted, result.error
      assert $rt_ensure_ran, 'ensure blocks run on interrupt'
      assert_match(/Interrupted\./, Transcript.buffer)
      refute RubyTalk::Evaluator.busy?
      assert_equal 3, threaded('1 + 2').value, 'the evaluator is usable again'
    end
  end

  def test_plain_rescue_in_user_code_cannot_swallow_the_interrupt
    with_driver(StopDriver) do
      result = threaded("begin; loop {}; rescue => e; :swallowed; end")
      assert_kind_of RubyTalk::Evaluator::Interrupted, result.error
    end
  end

  def test_second_stop_kills_code_that_catches_everything
    with_driver(StopDriver) do
      StopDriver.presses = 2
      result = threaded("loop { begin; sleep; rescue Exception; end }")
      assert_kind_of RubyTalk::Evaluator::Interrupted, result.error
      refute RubyTalk::Evaluator.busy?
    end
  end

  def test_stop_with_nothing_running
    refute RubyTalk::Evaluator.stop
  end

  def test_only_one_evaluation_at_a_time
    with_driver(JoinDriver) do
      nested = threaded("RubyTalk::Evaluator.evaluate('1', binding).error.class")
      assert_equal RubyTalk::Evaluator::Busy, nested.value
    end
  end

  def test_ctrl_c_in_the_terminal_stops_the_code
    with_driver(CtrlCDriver) do
      result = threaded('loop {}')
      assert_kind_of RubyTalk::Evaluator::Interrupted, result.error
    end
  end

  def test_losing_the_window_system_kills_the_worker
    with_driver(DyingDriver) do
      result = threaded('sleep')
      assert_kind_of RubyTalk::Evaluator::Interrupted, result.error
      refute RubyTalk::Evaluator.busy?
    end
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

  # --- Versions, history and originals ------------------------------------

  def make_class(name, parent = Object, &body)
    Object.const_set(name, Class.new(parent, &body))
  end

  def drop_classes(*names)
    names.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

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

  # --- Hierarchy --------------------------------------------------------

  def test_hierarchy_of_a_class_is_its_ancestors_then_all_its_subclasses
    make_class(:RtH1)
    make_class(:RtH2, RtH1)
    make_class(:RtH3, RtH2)
    make_class(:RtH4, RtH1)
    Class.new(RtH1) # anonymous classes are not listed
    rows = RubyTalk::Reflection.hierarchy(RtH1)
    assert_equal ['BasicObject', '  Object', '    RtH1', '      RtH2', '        RtH3', '      RtH4'], rows.map(&:label)
    assert_equal [0, 1, 2, 3, 4, 3], rows.map(&:depth)
    assert_equal ['BasicObject', '  Object', '    RtH1', '      RtH2', '        RtH3'],
                 RubyTalk::Reflection.hierarchy(RtH2).map(&:label), 'siblings are not part of it'
    assert_equal %w[BasicObject Object Numeric Integer], RubyTalk::Reflection.hierarchy(Integer).map { |r| r.klass.name }
  ensure
    drop_classes(:RtH4, :RtH3, :RtH2, :RtH1)
  end

  def test_hierarchy_of_a_module_lists_the_classes_that_include_it_directly
    Object.const_set(:RtMod, Module.new)
    make_class(:RtIncA) { include RtMod }
    make_class(:RtIncB, RtIncA) # inherits the include: not a direct includer
    assert_equal ['RtMod', '  RtIncA'], RubyTalk::Reflection.hierarchy(RtMod).map(&:label)
    assert_includes RubyTalk::Reflection.hierarchy(Comparable).map { |row| row.klass.name }, 'String'
  ensure
    drop_classes(:RtIncB, :RtIncA, :RtMod)
  end

  def test_hierarchy_of_object_is_capped_and_fast
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows = RubyTalk::Reflection.hierarchy(Object)
    assert_equal 'BasicObject', rows.first.label
    assert_operator rows.size, :<=, RubyTalk::Reflection::MAX_HIERARCHY
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
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
