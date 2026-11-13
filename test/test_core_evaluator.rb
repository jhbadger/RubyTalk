# frozen_string_literal: true

# Transcript, Evaluator (do it, Stop), and what the Debugger shows.
#   ruby test/test_core_evaluator.rb

require_relative 'support/core_case'

class CoreEvaluatorTest < CoreCase
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

  def debug_fixture
    accept("class RtDbg\nend\n")
    accept("def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", klass: RtDbg)
    accept("def build\n  tmp = 1\n  raise 'class side'\nend\n", klass: RtDbg, side: :class)
  end

  def run_it(source, binding = RubyTalk::Evaluator.new_binding)
    RubyTalk::Evaluator.evaluate(source, binding)
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
end
