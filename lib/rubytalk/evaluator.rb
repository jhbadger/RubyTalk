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
  module Evaluator
    Result = Struct.new(:ok, :value, :error)

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
      run { binding.eval(source, file, line) }
    end

    # Evaluate +source+ with +receiver+ as self (inspectors).
    def evaluate_in(source, receiver, file: 'inspector', line: 1)
      run { receiver.instance_eval(source, file, line) }
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

    def run(&block)
      raise Busy, 'Something is already running: stop it first (Cmd-. or System > Interrupt).' if busy?

      value = with_transcript_io { driver ? run_in_thread(&block) : block.call }
      Result.new(true, value, nil)
    rescue SystemExit => e
      ::Transcript.show_cr('exit ignored: use System > Quit so changes are saved.')
      Result.new(false, nil, e)
    rescue Interrupted => e
      ::Transcript.show_cr('Interrupted.')
      Result.new(false, nil, e)
    rescue Exception => e # rubocop:disable Lint/RescueException -- user code may raise anything
      ::Transcript.show_cr(format_error(e))
      Result.new(false, nil, e)
    end

    def run_in_thread(&block)
      worker = Thread.new do
        Thread.current.report_on_exception = false
        block.call
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
