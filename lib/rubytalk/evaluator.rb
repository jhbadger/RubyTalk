# frozen_string_literal: true

module RubyTalk
  # Evaluates source text for "do it" / "print it" / "inspect it".
  #
  # While code runs, $stdout and $stderr are pointed at the Transcript so that
  # `puts`, `p` and `warn` show up there. Errors never escape: they are
  # reported to the Transcript and returned in the Result for the GUI to show.
  #
  # With a +driver+ installed (the GUI does this), code runs on a worker thread
  # while the driver keeps the window system alive, so Stop can interrupt it:
  #
  #   driver.wait(worker)   # returns once the worker thread has finished
  #
  # With no driver (scripts, tests) code just runs on the calling thread.
  #
  # For the debugger, the binding at the point of every `raise` is remembered while
  # code runs. A Binding keeps its local variables alive after the stack unwinds, so
  # when a do it ends in an error, Result#failure can still show the locals of the
  # frame that raised, evaluate expressions there, and re-run the do it.
  module Evaluator
    # failure is nil unless the code raised: see Failure.
    Result = Struct.new(:ok, :value, :error, :failure)

    # binding: where the error was raised (nil if unknown); source: the text that was
    # evaluated; rerun: a callable that evaluates it again and returns a new Result.
    Failure = Struct.new(:binding, :source, :rerun)

    RaiseRecord = Struct.new(:exception, :binding)

    # How many recent raises to remember (most code rescues many exceptions internally).
    MAX_RECORDS = 100

    # Exceptions we recover from when running user code or replaying changes.
    # (Deliberately excludes NoMemoryError, SystemExit-as-quit and the like.)
    RECOVERABLE = [StandardError, ScriptError].freeze

    # Raised inside the running code by Stop. Not a StandardError on purpose, so
    # a plain `rescue => e` in the code being run does not swallow it; `ensure`
    # blocks still run.
    class Interrupted < Exception; end # rubocop:disable Lint/InheritException

    class Busy < StandardError; end

    # A second Stop within this many seconds kills the thread outright, for code
    # that catches everything (`rescue Exception`) and carries on.
    FORCE_AFTER = 3.0

    @driver = nil
    @current = nil
    @stopped_at = nil
    @killed = false

    class << self
      attr_accessor :driver
    end

    module_function

    # A fresh local-variable scope that sees the top level. Variables assigned
    # in one evaluation are visible to the next one that uses the same binding,
    # which is what gives a Workspace its Smalltalk-style temporaries.
    def new_binding
      TOPLEVEL_BINDING.eval('binding')
    end

    # Evaluate +source+ in a Binding (workspace temporaries).
    def evaluate(source, binding, file: 'workspace', line: 1)
      run(source: source, rerun: -> { evaluate(source, binding, file: file, line: line) }) do
        binding.eval(source, file, line)
      end
    end

    # Evaluate +source+ with +receiver+ as self (inspectors).
    def evaluate_in(source, receiver, file: 'inspector', line: 1)
      run(source: source, rerun: -> { evaluate_in(source, receiver, file: file, line: line) }) do
        receiver.instance_eval(source, file, line)
      end
    end

    # Is a do it running on a worker thread right now?
    def busy?
      !@current.nil?
    end

    # Interrupt the running code: raise Interrupted in it. A second call within
    # FORCE_AFTER seconds kills the thread. Returns false if nothing is running.
    def stop
      worker = @current or return false

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @stopped_at && now - @stopped_at < FORCE_AFTER
        @killed = true
        worker.kill
      else
        worker.raise(Interrupted, 'Interrupted')
      end
      @stopped_at = now
      true
    end

    def run(source: nil, rerun: nil, &block)
      records = []
      raise Busy, 'Something is already running: stop it first (Cmd-. or System > Interrupt).' if busy?

      value = with_transcript_io { driver ? run_in_thread(records, &block) : capturing(records, &block) }
      Result.new(true, value, nil, nil)
    rescue SystemExit => e
      ::Transcript.show_cr('exit ignored: use System > Quit so changes are saved.')
      Result.new(false, nil, e, nil)
    rescue Interrupted => e
      ::Transcript.show_cr('Interrupted.')
      Result.new(false, nil, e, nil)
    rescue Exception => e # rubocop:disable Lint/RescueException -- user code may raise anything
      ::Transcript.show_cr(format_error(e))
      Result.new(false, nil, e, failure_for(e, records, source, rerun))
    end

    # Run the block remembering the binding at each raise, on the current thread.
    def capturing(records)
      trace = TracePoint.new(:raise) do |event|
        exception = event.raised_exception
        next if records.any? { |record| record.exception.equal?(exception) } # keep the first raise

        records << RaiseRecord.new(exception, (event.binding rescue nil)) # rubocop:disable Style/RescueModifier
        records.shift if records.size > MAX_RECORDS
      end
      begin
        trace.enable(target_thread: Thread.current)
      rescue ArgumentError
        trace.enable # older Rubies: no per-thread targeting
      end
      yield
    ensure
      trace&.disable
    end

    def failure_for(error, records, source, rerun)
      record = records.reverse.find { |candidate| candidate.exception.equal?(error) }
      Failure.new(record&.binding, source, rerun)
    end

    def run_in_thread(records, &block)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        capturing(records, &block)
      end
      @current = worker
      @stopped_at = nil
      @killed = false
      wait_for(worker)
      raise Interrupted, 'Interrupted' if @killed

      worker.value # re-raises whatever the code raised, on this thread
    ensure
      @current = nil
    end

    def wait_for(worker)
      driver.wait(worker)
    rescue ::Interrupt
      stop # Ctrl-C in the terminal reaches the main thread: pass it on to the code
      retry
    rescue StandardError
      # The window system went away (quit while running): don't leave code running.
      @killed = true
      worker.kill
      worker.join(1)
    end

    def with_transcript_io
      out = $stdout
      err = $stderr
      $stdout = ::Transcript
      $stderr = ::Transcript
      yield
    ensure
      $stdout = out
      $stderr = err
    end

    def format_error(error, limit: 12, filter: true)
      lines = ["#{error.class}: #{error.message}"]
      trace = error.backtrace || []
      trace = filter_backtrace(trace) if filter
      lines.concat(trace.first(limit).map { |line| "    #{line}" })
      lines.join("\n")
    end

    def filter_backtrace(trace)
      trace.reject { |line| line.start_with?(RubyTalk::LIB_DIR) || line.include?('/gems/tk-') }
    end
  end
end
