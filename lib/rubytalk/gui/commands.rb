# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The commands behind the System menu and the class list that work on the whole image: running
    # Minitest tests, and filing code out to / in from plain Ruby files. Mixed into GUI
    # (GUI.run_tests_for, GUI.file_in ...).
    module Commands
      # Run the tests of +klass+ (a Minitest class itself, or the class FooTest/TestFoo/FooSpec
      # tests) and show the results.
      def run_tests_for(klass)
        name = Reflection.name_of(klass)
        classes = TestRunner.test_classes_for(klass)
        if classes.empty?
          ::Transcript.show_cr("No tests found for #{name}. Define a Minitest class named #{name}Test " \
                               '(class list right-click > New test class).')
          return
        end
        run_tests(classes, name)
      end

      # One test method of a test class.
      def run_test_method(klass, method_name)
        run_tests([klass], "#{Reflection.name_of(klass)}##{method_name}", method_name.to_s)
      end

      def run_all_user_tests
        classes = TestRunner.user_test_classes
        return ::Transcript.show_cr('No test classes have been created in RubyTalk yet.') if classes.empty?

        run_tests(classes, 'all your tests')
      end

      # Run on the evaluator (a worker thread: Stop works, the windows stay alive), then show a
      # results window whose Run Again / Run Failures call back into this.
      def run_tests(classes, title, filter = nil)
        runner = lambda do |only|
          report = nil
          result = Evaluator.run { report = TestRunner.run(classes, filter: only) }
          # A run that could not be made (not a failing test: those are results) is shown like any error.
          notify_error(result.error, result.failure) unless result.ok || result.error.is_a?(TestRunner::Error)
          result.ok ? report : nil
        end
        report = runner.call(filter)
        TestResultsWindow.new(title, report, runner: runner, filter: filter) if report
      end

      # System > File Out Changes as Ruby...: everything recorded in changes.rb, as plain Ruby.
      # +path+ skips the dialog (tests, scripts).
      def file_out_changes(path = nil)
        path ||= choose_save_file('rubytalk_changes.rb') or return
        write_filed_out(Exchange.all_source, path, 'all changes')
      end

      # Class list > File out class...: the changes made to +klass+, as plain Ruby.
      def file_out_class(klass, path = nil)
        name = Reflection.name_of(klass)
        text = Exchange.class_source(klass)
        return ::Transcript.show_cr("Nothing to file out: #{name} has no recorded changes.") unless text

        path ||= choose_save_file("#{name.gsub('::', '_').gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase}.rb") or return
        write_filed_out(text, path, name)
      end

      # System > File In...: plain Ruby (taken apart into per-method changes) or RubyTalk's own
      # changes format. Returns the Exchange::Summary, or nil if cancelled.
      def file_in(path = nil)
        path ||= choose_open_file or return
        summary = Exchange.file_in_path(path)
        ::Transcript.show_cr("Filed in #{File.basename(path)}: #{summary}")
        summary.errors.each { |error| ::Transcript.show_cr("  #{error}") }
        summary
      rescue SystemCallError => e
        ::Transcript.show_cr("Could not read #{path}: #{e.message}")
        nil
      end

      def write_filed_out(text, path, what)
        File.write(path, text, encoding: 'UTF-8')
        ::Transcript.show_cr("Filed out #{what} to #{path}")
        path
      rescue SystemCallError => e
        ::Transcript.show_cr("Could not write #{path}: #{e.message}")
        nil
      end

      # The file dialogs start in the folder of the current image. nil if cancelled.
      def choose_save_file(initial_name)
        chosen = Tk.tk_call('tk_getSaveFile', '-initialfile', initial_name.dup, '-defaultextension', '.rb',
                            '-initialdir', dialog_directory, '-title', 'File out as Ruby').to_s
        chosen.empty? ? nil : chosen
      end

      def choose_open_file
        chosen = Tk.tk_call('tk_getOpenFile', '-initialdir', dialog_directory, '-title', 'File in',
                            '-filetypes', '{{Ruby files} .rb} {{All files} *}').to_s
        chosen.empty? ? nil : chosen
      end

      def dialog_directory
        RubyTalk.changes ? File.dirname(RubyTalk.changes.path) : Dir.pwd
      end
    end

    extend Commands
  end
end
