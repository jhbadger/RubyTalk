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

# A documented class used by the class-comment tests.
# It has a second line.
class RtDocumented
end

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

  # --- Debugger support: binding at the raise, frames, source, variables -------

  def debug_fixture
    accept("class RtDbg\nend\n")
    accept("def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", klass: RtDbg)
    accept("def build\n  tmp = 1\n  raise 'class side'\nend\n", klass: RtDbg, side: :class)
  end

  def run_it(source, binding = RubyTalk::Evaluator.new_binding)
    RubyTalk::Evaluator.evaluate(source, binding)
  end

  def test_failure_keeps_the_locals_of_the_frame_that_raised
    result = run_it("x = 5\ny = x * 2\nraise 'boom'")
    refute result.ok
    assert_equal 10, result.failure.binding.local_variable_get(:y)
    assert_equal "x = 5\ny = x * 2\nraise 'boom'", result.failure.source
    assert_nil run_it('1 + 1').failure, 'no failure when nothing went wrong'
  end

  def test_failure_in_a_method_has_that_methods_locals_and_receiver
    debug_fixture
    result = run_it('RtDbg.new.explode(21)')
    binding = result.failure.binding
    assert_equal 42, binding.local_variable_get(:local)
    assert_equal 21, binding.local_variable_get(:n)
    assert_instance_of RtDbg, binding.receiver
    assert_equal 'rubytalk:RtDbg', binding.source_location[0]
  ensure
    drop_classes(:RtDbg)
  end

  def test_failure_from_a_c_method_still_has_a_binding
    result = run_it("here = :marker\n1 / 0")
    assert_kind_of ZeroDivisionError, result.error
    assert_equal :marker, result.failure.binding.local_variable_get(:here)
    assert_equal 'workspace', result.failure.binding.source_location[0]
  end

  def test_failure_belongs_to_the_exception_that_escaped_not_one_rescued_earlier
    code = "begin; raise 'rescued'; rescue; end\nlocal = 1\n300.times { begin; raise 'n'; rescue; end }\nraise 'escaped'"
    result = run_it(code)
    assert_equal 'escaped', result.error.message
    assert_equal 1, result.failure.binding.local_variable_get(:local)
  end

  def test_failure_works_on_a_worker_thread_too
    with_driver(JoinDriver) do
      result = run_it("seen = 9\nraise 'on a worker'")
      assert_equal 9, result.failure.binding.local_variable_get(:seen)
    end
  end

  def test_rerun_evaluates_the_same_source_again
    $rt_runs = 0
    binding = RubyTalk::Evaluator.new_binding
    result = run_it("$rt_runs += 1\nraise 'again'", binding)
    again = result.failure.rerun.call
    assert_equal 2, $rt_runs
    assert_equal 'again', again.error.message
    assert_equal 3, again.failure.rerun.call.then { $rt_runs }
  end

  def test_an_interrupt_has_no_failure_to_debug
    with_driver(StopDriver) do
      assert_nil run_it('loop {}').failure
    end
  end

  def test_stack_frames_hide_the_plumbing_and_carry_the_binding
    debug_fixture
    result = run_it('RtDbg.new.explode(21)')
    frames = RubyTalk::Stack.frames(result.error, result.failure.binding)
    assert_equal 'rubytalk:RtDbg', frames.first.path
    assert_equal 3, frames.first.lineno
    assert frames.first.binding
    assert_includes frames.map(&:path), 'workspace'
    refute(frames.any? { |frame| RubyTalk::Stack.internal?(frame.path) })
    assert_nil frames.last.binding
    assert_match(/rubytalk:RtDbg:3 in /, frames.first.to_s)
  ensure
    drop_classes(:RtDbg)
  end

  def test_stack_frames_from_a_plain_backtrace
    error = RuntimeError.new('x')
    error.set_backtrace(["a.rb:3:in `foo'", "b.rb:9:in `bar'"])
    frames = RubyTalk::Stack.frames(error)
    assert_equal [['a.rb', 3, 'foo'], ['b.rb', 9, 'bar']], frames.map { |f| [f.path, f.lineno, f.label] }
  end

  def test_stack_variables
    debug_fixture
    result = run_it('RtDbg.new.explode(21)')
    rows = RubyTalk::Stack.variables(result.failure.binding)
    assert_equal 'self', rows.first.first
    assert_instance_of RtDbg, rows.first.last
    assert_equal [['n', 21], ['local', 42]], rows.drop(1).first(2)
    assert_empty RubyTalk::Stack.variables(nil)
  ensure
    drop_classes(:RtDbg)
  end

  def test_stack_source_views
    debug_fixture
    result = run_it("1\nRtDbg.new.explode(21)")
    frames = RubyTalk::Stack.frames(result.error, result.failure.binding)

    text, current, first = RubyTalk::Stack.source_view(frames.first, result.failure.source, @changes)
    assert_equal "def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", text
    assert_equal [3, 1], [current, first], 'the raise is on line 3 of the method source'

    doit = frames.find { |frame| frame.path == 'workspace' }
    text, current, = RubyTalk::Stack.source_view(doit, result.failure.source, @changes)
    assert_equal "1\nRtDbg.new.explode(21)", text
    assert_equal 2, current

    missing = RubyTalk::Stack::Frame.new('/no/such/file.rb', 3, 'x')
    text, current, = RubyTalk::Stack.source_view(missing, nil, @changes)
    assert_match(/source not available/, text)
    assert_nil current
  ensure
    drop_classes(:RtDbg)
  end

  def test_stack_source_view_of_a_real_file_shows_a_window_around_the_line
    frame = RubyTalk::Stack::Frame.new(__FILE__, __LINE__ + 1, 'x')
    marker = 'RT_MARKER_LINE_FOR_STACK_TEST'
    text, current, first = RubyTalk::Stack.source_view(frame, nil, @changes)
    assert_includes text.lines[current - 1], 'RT_MARKER_LINE_FOR_STACK_TEST'
    assert_equal frame.lineno, first + current - 1
    assert_operator text.lines.size, :<=, 81
    refute_nil marker
  end

  def test_stack_method_targets
    debug_fixture
    instance = RubyTalk::Stack.frames(run_it('RtDbg.new.explode(1)').error).first
    assert_equal [RtDbg, :instance, 'explode'], RubyTalk::Stack.method_target(instance, @changes)
    klass_side = RubyTalk::Stack.frames(run_it('RtDbg.build').error).first
    assert_equal [RtDbg, :class, 'build'], RubyTalk::Stack.method_target(klass_side, @changes)

    frame = ->(label, binding = nil) { RubyTalk::Stack::Frame.new('x.rb', 1, label, binding) }
    assert_equal [String, :instance, 'upcase'], RubyTalk::Stack.method_target(frame.call('block in String#upcase'), @changes)
    assert_equal [Integer, :class, 'sqrt'], RubyTalk::Stack.method_target(frame.call('Integer.sqrt'), @changes)
    assert_nil RubyTalk::Stack.method_target(frame.call('<main>'), @changes)
    assert_nil RubyTalk::Stack.method_target(frame.call('NoSuchClassAnywhere#foo'), @changes)
    assert_equal [String, :instance, 'foo'], RubyTalk::Stack.method_target(frame.call('foo', 'str'.instance_eval { binding }), @changes)
  ensure
    drop_classes(:RtDbg)
  end

  def test_stack_method_names
    names = ['block (2 levels) in Foo#bar', 'Foo.baz', 'bar', '<main>', 'Foo#+', nil].map { |l| RubyTalk::Stack.method_name(l) }
    assert_equal ['bar', 'baz', 'bar', nil, '+', nil], names
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

  # --- Find and replace ----------------------------------------------------

  def finder
    RubyTalk::Finder
  end

  def spans(found)
    found.map { |m| [m.first, m.last] }
  end

  def test_finder_plain_matches
    text = "alpha beta Alpha\nalpha"
    assert_equal [[0, 5], [11, 16], [17, 22]], spans(finder.matches(text, 'alpha')), 'case-insensitive by default'
    assert_equal [[0, 5], [17, 22]], spans(finder.matches(text, 'alpha', case_sensitive: true))
    assert_equal [[0, 3]], spans(finder.matches('a.b a-b', 'a.b')), 'a plain pattern is literal: the dot is not a wildcard'
    assert_empty finder.matches(text, '')
    assert_empty finder.matches(text, 'zzz')
    assert_empty finder.matches('', 'a')
  end

  def test_finder_regexp_matches_and_errors
    text = 'x1 y22 z333'
    assert_equal %w[1 22 333], finder.matches(text, '\d+', regexp: true).map { |m| m.data[0] }
    assert(finder.matches(text, 'x*', regexp: true).none? { |m| m.first == m.last }, 'empty matches are skipped')
    assert_equal [[0, 1]], spans(finder.matches("a\nb", '^a', regexp: true))
    assert_raises(RubyTalk::Finder::Error) { finder.matches('x', '(', regexp: true) }
    assert_equal 1, finder.matches('a(b', '(').size, 'the same text is fine as a plain pattern'
  end

  def test_finder_offsets_are_characters_and_convert_to_tk_indices
    text = "é = :sym\nsecond é line"
    match = finder.matches(text, 'sym').first
    assert_equal [5, 8], [match.first, match.last], 'characters, not bytes'
    assert_equal '1.5', finder.index(text, match.first)
    assert_equal '2.0', finder.index(text, finder.matches(text, 'second').first.first)
    assert_equal '2.7', finder.index(text, finder.matches(text, 'é').last.first)
    assert_equal '1.0', finder.index(text, 0)
    assert_equal '2.0', finder.index("a\nb", 2)
    assert_equal '1.1', finder.index('a', 1)
  end

  def test_finder_indexer_agrees_with_index
    text = "é = :sym\nsecond é line\n\nlast"
    indexer = finder.indexer(text)
    (0..text.size).each { |offset| assert_equal finder.index(text, offset), indexer.call(offset), "offset #{offset}" }
    assert_equal '1.0', finder.indexer('').call(0)
  end

  def test_finder_pick_moves_forward_and_back_and_wraps
    found = finder.matches('a b a b a', 'a')
    assert_equal [0, 4, 8], found.map(&:first)
    pick = ->(offset, forward) { finder.pick(found, offset, forward: forward).then { |m, wrapped| [m.first, wrapped] } }
    assert_equal [0, false], pick.call(0, true)
    assert_equal [4, false], pick.call(1, true)
    assert_equal [8, false], pick.call(5, true)
    assert_equal [0, true], pick.call(9, true), 'forward past the last wraps to the first'
    assert_equal [4, false], pick.call(8, false)
    assert_equal [8, true], pick.call(0, false), 'backward before the first wraps to the last'
    assert_equal [nil, false], finder.pick([], 0)
  end

  def test_finder_replacements
    match = finder.matches('John Smith', '(\w+) (\w+)', regexp: true).first
    assert_equal 'Smith, John', finder.replacement(match, '\2, \1', regexp: true)
    assert_equal 'John Smith!', finder.replacement(match, '\0!', regexp: true)
    assert_equal '[John Smith]', finder.replacement(match, '[\&]', regexp: true)
    assert_equal 'a\b', finder.replacement(match, 'a\\\\b', regexp: true), 'two backslashes make one'
    assert_equal '\1 stays', finder.replacement(finder.matches('x', 'x').first, '\1 stays'), 'plain replacements are literal'

    assert_equal ['Smith, John', 1], finder.replace_all('John Smith', '(\w+) (\w+)', '\2, \1', regexp: true)
    assert_equal ['b b b', 3], finder.replace_all('a a A', 'a', 'b')
    assert_equal ['b b A', 2], finder.replace_all('a a A', 'a', 'b', case_sensitive: true)
    assert_equal ['a a A', 0], finder.replace_all('a a A', 'q', 'z')
    assert_equal ['é-é', 1], finder.replace_all('éxé', 'x', '-')
    assert_equal ['ñññ', 3], finder.replace_all('aaa', 'a', 'ñ'), 'replacing with multi-byte text'
  end

  # --- Test runner ---------------------------------------------------------

  def sample_tests
    RubyTalk::TestRunner.load_minitest
    accept("class RtCalc\nend\n")
    accept("def double(x)\n  x * 2\nend\n", klass: RtCalc)
    accept("class RtCalcTest < Minitest::Test\nend\n")
    {
      'test_double' => "assert_equal 4, RtCalc.new.double(2)",
      'test_wrong' => "assert_equal 5, RtCalc.new.double(2)",
      'test_error' => "RtCalc.new.nope",
      'test_skipped' => "skip 'later'",
      'test_prints' => "puts 'hello from a test'"
    }.each { |name, body| accept("def #{name}\n  #{body}\nend\n", klass: RtCalcTest) }
  end

  def drop_sample_tests
    %i[RtCalcTest RtCalc RtOtherTest RtSpecified TestRtSpecified RtSpecifiedSpec].each do |name|
      next unless Object.const_defined?(name)

      RubyTalk::TestRunner.forget(Object.const_get(name))
      Object.send(:remove_const, name)
    end
  end

  def test_test_classes_are_found_by_name
    sample_tests
    assert_equal [RtCalcTest], RubyTalk::TestRunner.test_classes_for(RtCalc)
    assert_equal [RtCalcTest], RubyTalk::TestRunner.test_classes_for(RtCalcTest), 'a test class runs itself'
    assert_empty RubyTalk::TestRunner.test_classes_for(String)
    accept("class RtSpecified\nend\n")
    accept("class TestRtSpecified < Minitest::Test\nend\n")
    accept("class RtSpecifiedSpec < Minitest::Test\nend\n")
    names = RubyTalk::TestRunner.test_classes_for(RtSpecified).map(&:name)
    assert_equal %w[RtSpecifiedSpec TestRtSpecified], names.sort
  ensure
    drop_sample_tests
  end

  def test_running_tests_reports_every_kind_of_outcome
    sample_tests
    report = RubyTalk::Evaluator.with_transcript_io { RubyTalk::TestRunner.run([RtCalcTest]) }
    assert_equal({ pass: 2, fail: 1, error: 1, skip: 1 },
                 %i[pass fail error skip].to_h { |status| [status, report.count(status)] })
    refute report.green?
    assert_equal %w[RtCalcTest#test_error RtCalcTest#test_wrong], report.failures.map(&:label).sort
    assert_match(/5 tests, \d+ assertions, 1 failure, 1 error, 1 skip in \d+\.\d\ds/, report.summary)

    wrong = report.outcomes.find { |o| o.name == 'test_wrong' }
    assert_equal :fail, wrong.status
    assert_includes wrong.message, 'Expected: 5'
    assert_match(/rubytalk:RtCalcTest:2/, wrong.location)
    error = report.outcomes.find { |o| o.name == 'test_error' }
    assert_equal :error, error.status
    assert_match(/NoMethodError/, error.message)
    assert_equal 'later', report.outcomes.find { |o| o.name == 'test_skipped' }.message
    assert_includes Transcript.buffer, 'hello from a test', 'output printed by a test goes to the Transcript'
  ensure
    drop_sample_tests
  end

  def test_running_one_test_by_name_is_green
    sample_tests
    report = RubyTalk::Evaluator.with_transcript_io { RubyTalk::TestRunner.run([RtCalcTest], filter: 'test_double') }
    assert_equal ['test_double'], report.outcomes.map(&:name)
    assert report.green?
    assert_match(/\A1 test, 1 assertion, 0 failures, 0 errors, 0 skips in /, report.summary)
    only_failures = RubyTalk::TestRunner.run([RtCalcTest], filter: /\Atest_(wrong|error)\z/)
    assert_equal %w[test_error test_wrong], only_failures.outcomes.map(&:name).sort
  ensure
    drop_sample_tests
  end

  def test_user_test_classes_are_only_those_created_here
    sample_tests
    assert_includes RubyTalk::TestRunner.user_test_classes(@changes), RtCalcTest
    refute(RubyTalk::TestRunner.user_test_classes(@changes).any? { |klass| klass.name.start_with?('Minitest') })
  ensure
    drop_sample_tests
  end

  def test_removing_a_test_class_takes_it_out_of_minitest
    sample_tests
    klass = RtCalcTest
    assert_includes Minitest::Runnable.runnables, klass
    RubyTalk::Compiler.remove_class(klass, @changes)
    refute_includes Minitest::Runnable.runnables, klass
  ensure
    drop_sample_tests
  end

  def test_runner_without_minitest_says_so
    RubyTalk::TestRunner.stub(:load_minitest, false) do
      error = assert_raises(RubyTalk::TestRunner::Error) { RubyTalk::TestRunner.run([]) }
      assert_match(/not installed/, error.message)
    end
  end

  def test_test_class_template
    text = RubyTalk::Reflection.test_class_template('RtThing')
    assert_equal "# Tests for RtThing.\nclass RtThingTest < Minitest::Test\n  def test_something\n    assert true\n  end\nend\n", text
    assert RubyTalk::Source.syntax_error(text).nil?
  end

  # --- Class comments ---------------------------------------------------

  DOC = "# A documented class used by the class-comment tests.\n# It has a second line.\n"

  def test_split_comment
    assert_equal ["# a\n# b\n", "class X\nend\n"], RubyTalk::Source.split_comment("# a\n# b\nclass X\nend\n")
    assert_equal ["# a\n", "class X\nend\n"], RubyTalk::Source.split_comment("\n\n# a\nclass X\nend\n"), 'leading blanks skipped'
    assert_equal ['', "class X\nend\n"], RubyTalk::Source.split_comment("class X\nend\n")
    assert_equal ["# only\n", ''], RubyTalk::Source.split_comment("# only\n")
    assert_equal ['', ''], RubyTalk::Source.split_comment('')
  end

  def test_class_comment_comes_from_the_source_file_for_ruby_classes
    assert_equal DOC, RubyTalk::Reflection.class_comment(RtDocumented, @changes)
    assert_equal "#{DOC}class RtDocumented < Object\nend\n", RubyTalk::Reflection.class_definition(RtDocumented)
    assert_equal '', RubyTalk::Reflection.class_comment(String, @changes), 'C classes have no source file'
    assert_equal "class String < Object\n  include Comparable\nend\n", RubyTalk::Reflection.class_definition(String)
    assert_equal '', RubyTalk::Reflection.file_comment(Class.new), 'anonymous classes do not raise'
  end

  def test_magic_comments_are_not_class_comments
    path = File.join(@dir, 'magic.rb')
    File.write(path, "# frozen_string_literal: true\n# Real doc.\nclass RtMagic\nend\n")
    load path
    assert_equal "# Real doc.\n", RubyTalk::Reflection.file_comment(RtMagic)
  ensure
    drop_classes(:RtMagic)
  end

  def test_editing_the_comment_of_an_existing_class
    shown = RubyTalk::Reflection.class_definition(RtDocumented)
    assert_empty accept(shown).then { @changes.entries }, 'accepting it unchanged logs nothing'

    out = accept("# New words.\nclass RtDocumented < Object\nend\n")
    assert out.ok, out.message
    entry = @changes.open_entry('RtDocumented', 'comment')
    assert_equal "# New words.\nclass RtDocumented < Object\nend\n", entry.source
    assert_equal "# New words.\n", RubyTalk::Reflection.class_comment(RtDocumented, @changes)
    assert_equal "# New words.\nclass RtDocumented < Object\nend\n", RubyTalk::Reflection.class_definition(RtDocumented)

    accept("# Newer words.\nclass RtDocumented < Object\nend\n")
    assert_equal 1, @changes.entries.size, 'editing again replaces the comment entry'

    accept("class RtDocumented < Object\nend\n") # cleared: back to the original
    assert_nil @changes.open_entry('RtDocumented', 'comment')
    assert_equal DOC, RubyTalk::Reflection.class_comment(RtDocumented, @changes)

    accept("# New words.\nclass RtDocumented < Object\nend\n")
    accept(RubyTalk::Reflection.file_comment(RtDocumented) + "class RtDocumented < Object\nend\n") # original text back
    assert_empty @changes.entries
  end

  def test_comment_on_a_c_class_persists_across_a_restart
    accept("# Strings of text.\nclass String < Object\n  include Comparable\nend\n")
    assert_equal "# Strings of text.\n", RubyTalk::Reflection.class_comment(String, @changes)
    assert_match(/\A# Strings of text\.\nclass String < Object\n  include Comparable\nend\n\z/,
                 RubyTalk::Reflection.class_definition(String))
    @changes.save!
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      RubyTalk.setup(#{@dir.inspect})
      print RubyTalk::Reflection.class_comment(String)
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal "# Strings of text.\n", out.lines.last(1).join
  end

  def test_comment_of_a_class_you_created_travels_with_its_definition
    accept("# Mine.\nclass RtCmt\nend\n")
    assert_equal "# Mine.\nclass RtCmt\nend\n", RubyTalk::Reflection.class_definition(RtCmt)
    accept("# Mine, revised.\nclass RtCmt\nend\n")
    assert_equal "# Mine, revised.\nclass RtCmt\nend\n", RubyTalk::Reflection.class_definition(RtCmt)
    assert_equal [:class], @changes.entries.map(&:kind)
  ensure
    drop_classes(:RtCmt)
  end

  def test_new_class_template_has_the_comment_above_the_class
    assert_equal "# Describe NewClass here.\nclass NewClass < Object\nend\n", RubyTalk::Reflection.new_class_template
    out = accept(RubyTalk::Reflection.new_class_template.sub('class NewClass', 'class RtFromTemplate'))
    assert out.ok, out.message
    assert_match(/\A# Describe NewClass here\.\nclass RtFromTemplate/, RubyTalk::Reflection.class_definition(RtFromTemplate))
  ensure
    drop_classes(:RtFromTemplate)
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
