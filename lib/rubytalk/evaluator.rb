# frozen_string_literal: true

module RubyTalk
  # Evaluates source text for "do it" / "print it" / "inspect it".
  #
  # While code runs, $stdout and $stderr are pointed at the Transcript so that
  # `puts`, `p`, `warn` and friends show up there. Errors never escape: they are
  # reported to the Transcript and returned in the Result for the GUI to show.
  module Evaluator
    Result = Struct.new(:ok, :value, :error)

    # Exceptions we recover from when running user code or replaying changes.
    # (Deliberately excludes NoMemoryError, SystemExit-as-quit and the like.)
    RECOVERABLE = [StandardError, ScriptError].freeze

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

    def run
      value = with_transcript_io { yield }
      Result.new(true, value, nil)
    rescue SystemExit => e
      ::Transcript.show_cr('exit ignored: use System > Quit so changes are saved.')
      Result.new(false, nil, e)
    rescue Exception => e # rubocop:disable Lint/RescueException -- user code may raise anything
      ::Transcript.show_cr(format_error(e))
      Result.new(false, nil, e)
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
