# frozen_string_literal: true

module RubyTalk
  # Runs Minitest tests from inside RubyTalk and reports the outcomes as plain data (the
  # GUI shows them; nothing here needs a window). Tests are ordinary Minitest classes
  # created in the browser, e.g. `class FooTest < Minitest::Test`.
  #
  # Minitest is driven directly, one test method at a time, with our own reporter (not through
  # Minitest.run or autorun, so nothing runs at exit and no command line is parsed). Minitest 6
  # renamed its running methods (see run_method), so only `runnable_methods` and the per-method
  # runner are relied on, and the filtering is done here.
  module TestRunner
    class Error < StandardError; end

    # status: :pass, :fail, :error or :skip
    Outcome = Struct.new(:class_name, :name, :status, :message, :location, :time) do
      def label
        "#{class_name}##{name}"
      end
    end

    Report = Struct.new(:outcomes, :assertions, :seconds, :classes) do
      def count(status)
        outcomes.count { |outcome| outcome.status == status }
      end

      def failures
        outcomes.select { |outcome| %i[fail error].include?(outcome.status) }
      end

      # Green: nothing failed or errored (skips do not make a run red).
      def green?
        failures.empty?
      end

      def summary
        parts = ["#{outcomes.size} test#{'s' unless outcomes.size == 1}", "#{assertions} assertion#{'s' unless assertions == 1}"]
        parts << "#{count(:fail)} failure#{'s' unless count(:fail) == 1}"
        parts << "#{count(:error)} error#{'s' unless count(:error) == 1}"
        parts << "#{count(:skip)} skip#{'s' unless count(:skip) == 1}"
        "#{parts.join(', ')} in #{format('%.2f', seconds)}s"
      end
    end

    module_function

    # Loads Minitest (not autorun). False if the gem is not installed.
    def load_minitest
      require 'minitest'
      true
    rescue LoadError
      false
    end

    # Every test class: Minitest's own list where it has one, plus a scan for subclasses, so this does not
    # depend on how a given Minitest version keeps its registry.
    def runnables
      return [] unless defined?(::Minitest::Runnable)

      registered = ::Minitest::Runnable.respond_to?(:runnables) ? Array(::Minitest::Runnable.runnables) : []
      scanned = ObjectSpace.each_object(Class).select { |klass| klass < ::Minitest::Runnable }
      (registered + scanned).uniq.select { |klass| Reflection.listed?(klass) }
    end

    # The test classes to run for +klass+: itself if it is a test class, else FooTest, TestFoo or
    # FooSpec if they exist.
    def test_classes_for(klass)
      return [] unless load_minitest

      return [klass] if klass.is_a?(Class) && klass <= ::Minitest::Runnable

      name = Reflection.name_of(klass)
      wanted = ["#{name}Test", "Test#{name}", "#{name}Spec"]
      runnables.select { |candidate| wanted.include?(Reflection.name_of(candidate)) }
    end

    # Every test class created in RubyTalk.
    def user_test_classes(changes = RubyTalk.changes)
      runnables.select { |klass| changes&.user_defined?(Reflection.name_of(klass)) }
    end

    # Take a removed class out of Minitest's list so it is not run later.
    def forget(klass)
      return unless defined?(::Minitest::Runnable) && ::Minitest::Runnable.respond_to?(:runnables)

      ::Minitest::Runnable.runnables.delete(klass)
    end

    # Run +classes+ (optionally only test methods matching +filter+, a Regexp or String).
    # Output the tests print goes wherever $stdout points (the Transcript, inside the evaluator).
    def run(classes, filter: nil)
      raise Error, 'Minitest is not installed (gem install minitest).' unless load_minitest

      collector = collector_class.new
      reporter = ::Minitest::CompositeReporter.new
      reporter << collector
      reporter.start
      ::Minitest.seed = Random.new_seed % 0xFFFF if ::Minitest.respond_to?(:seed=) # newer Minitest needs it; 5.14 does not have it
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      classes.each do |klass|
        method_names(klass, filter).each { |name| run_method(klass, name, reporter) }
      end
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Report.new(collector.outcomes, collector.assertions, seconds, classes)
    end

    # The test methods of +klass+ (in Minitest's order), narrowed by +filter+: a String is an exact method
    # name (or "Class#method"), a Regexp or a "/pattern/" String is matched against both forms.
    def method_names(klass, filter)
      names = klass.runnable_methods
      return names unless filter

      pattern = filter.is_a?(String) && (match = filter.match(%r{\A/(.*)/\z})) ? Regexp.new(match[1]) : filter
      names.select { |name| pattern === name || pattern === "#{klass}##{name}" }
    rescue NotImplementedError
      [] # an abstract runnable, such as Minitest::Runnable itself
    end

    # Run one test method and have the reporter record it. Minitest 5 calls this run_one_method(klass,
    # name, reporter) and uses Runnable.run(reporter, options) for a whole class; Minitest 6 renamed
    # the per-method one to Runnable.run(klass, name, reporter). The arity tells them apart.
    def run_method(klass, name, reporter)
      if klass.method(:run).arity == 3
        klass.run(klass, name, reporter)
      else
        klass.run_one_method(klass, name, reporter)
      end
    end

    # The reporter is built on first use because it needs Minitest to be loaded.
    def collector_class
      @collector_class ||= Class.new(::Minitest::AbstractReporter) do
        attr_reader :outcomes, :assertions

        def initialize
          super
          @outcomes = []
          @assertions = 0
        end

        def record(result)
          @assertions += result.assertions.to_i
          @outcomes << TestRunner.outcome_of(result)
        end
      end
    end

    def outcome_of(result)
      failure = result.failures.first
      status = if result.skipped? then :skip
               elsif result.failures.empty? then :pass
               elsif result.failures.any? { |f| f.is_a?(::Minitest::UnexpectedError) } then :error
               else :fail
               end
      message = failure ? failure.message.to_s : ''
      location = failure&.location.to_s
      Outcome.new(result.klass.to_s, result.name.to_s, status, message, location.empty? ? nil : location, result.time.to_f)
    end
  end
end
