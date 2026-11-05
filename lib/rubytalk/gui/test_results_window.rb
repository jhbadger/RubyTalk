# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The result of a test run: a green or red bar, one row per test (failures first), and the
    # message and location of the selected one. Run Again repeats the run; Run Failures repeats
    # only the tests that failed; Edit Test (or double-click) opens the test in the browser.
    #
    # +runner+ is a callable taking a filter (nil, a String or a Regexp) and returning a new
    # TestRunner::Report, or nil if the run could not be made.
    class TestResultsWindow
      extend MainThreadNew

      GREEN = '#2da44e'
      RED = '#cf222e'
      WORDS = { pass: 'PASS ', fail: 'FAIL ', error: 'ERROR', skip: 'skip ' }.freeze
      ORDER = { error: 0, fail: 1, skip: 2, pass: 3 }.freeze

      attr_reader :report

      def initialize(title, report, runner: nil, filter: nil)
        @title = title
        @runner = runner
        @filter = filter
        @window = TkToplevel.new
        GUI.window_title(@window, "Tests: #{title}")
        GUI.place(@window, kind: :tests)
        build
        GUI.windows << self
        show(report)
      end

      private

      def build
        @bar = TkLabel.new(@window, text: +'', foreground: 'white', font: 'TkHeadingFont', pady: 8)
        @bar.pack(side: 'top', fill: 'x')
        @summary = TkLabel.new(@window, text: +'', anchor: 'w')
        @summary.pack(side: 'top', fill: 'x', padx: 6, pady: 2)
        panes = TkFrame.new(@window)
        panes.pack(side: 'top', fill: 'both', expand: 1)
        @list = SelectableList.new(panes, width: 56, height: 12) { |outcome| outcome_selected(outcome) }
        @list.frame.pack(side: 'left', fill: 'y')
        @list.box.bind('Double-Button-1') { GUI.safely { edit_test } }
        frame, @detail = GUI.scrolled_text(panes, width: 70, height: 12, wrap: 'word')
        frame.pack(side: 'left', fill: 'both', expand: 1)
        bar = TkFrame.new(@window)
        bar.pack(side: 'top', fill: 'x', pady: 4)
        @status = TkLabel.new(bar, text: +'', anchor: 'w')
        @status.pack(side: 'left', fill: 'x', expand: 1, padx: 6)
        TkButton.new(bar, text: 'Close', command: proc { @window.destroy }).pack(side: 'right', padx: 4)
        TkButton.new(bar, text: 'Edit Test', command: proc { GUI.safely { edit_test } }).pack(side: 'right')
        TkButton.new(bar, text: 'Run Failures', command: proc { GUI.safely { run_failures } }).pack(side: 'right')
        TkButton.new(bar, text: 'Run Again', command: proc { GUI.safely { run_again } }).pack(side: 'right')
      end

      def show(report)
        @report = report
        @bar.configure(text: bar_text(report), background: (report.green? ? GREEN : RED).dup)
        @summary.configure(text: report.summary.dup)
        rows = report.outcomes.sort_by { |outcome| [ORDER.fetch(outcome.status), outcome.label] }
        @list.set(rows, rows.map { |outcome| row_label(outcome) })
        colour_rows(rows)
        status('')
        return @detail.delete('1.0', 'end') if rows.empty?

        @list.select_index(rows.index { |outcome| %i[error fail].include?(outcome.status) } || 0)
      end

      def bar_text(report)
        count = report.outcomes.size
        return 'No tests were run' if count.zero?
        return "All #{count} test#{'s' unless count == 1} passed#{skips_note(report)}" if report.green?

        "#{report.failures.size} of #{count} test#{'s' unless count == 1} failed"
      end

      def skips_note(report)
        skipped = report.count(:skip)
        skipped.zero? ? '' : " (#{skipped} skipped)"
      end

      def row_label(outcome)
        "#{WORDS.fetch(outcome.status)}  #{outcome.label}  (#{format('%.3f', outcome.time)}s)"
      end

      # Red, green and grey rows, in the editor palette's colours for the current appearance.
      def colour_rows(rows)
        palette = Highlighter::PALETTES.fetch(GUI.dark_background?(@list.box) ? :dark : :light)
        colours = { pass: :string, fail: :regexp, error: :regexp, skip: :comment }
        rows.each_with_index do |outcome, index|
          Tk.tk_call(@list.box.path, 'itemconfigure', index, '-foreground', palette.fetch(colours.fetch(outcome.status)).dup)
        end
      end

      def outcome_selected(outcome)
        @detail.delete('1.0', 'end')
        return unless outcome

        @detail.insert('end', detail_text(outcome))
      end

      def detail_text(outcome)
        case outcome.status
        when :pass then "Passed in #{format('%.3f', outcome.time)}s."
        when :skip then "Skipped: #{outcome.message}"
        else "#{outcome.message}\n#{"\nat #{outcome.location}" if outcome.location}"
        end
      end

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      def run_again
        rerun(@filter)
      end

      # Only the tests that failed or errored last time.
      def run_failures
        failed = @report.failures
        return status('Nothing failed.') if failed.empty?

        rerun(/\A(?:#{failed.map { |outcome| Regexp.escape(outcome.name) }.uniq.join('|')})\z/)
      end

      def rerun(filter)
        return status('Cannot run these tests again.') unless @runner
        return status('Something is already running: press Cmd-. to stop it first.') if Evaluator.busy?

        report = @runner.call(filter)
        report ? show(report) : status('The run failed: see the Transcript.')
      end

      def edit_test
        outcome = @list.selected_value or return status('Select a test first.')

        klass = Reflection.lookup(outcome.class_name)
        return status("Cannot find #{outcome.class_name}.") unless klass

        Browser.open(klass, method: outcome.name, side: :instance)
      end
    end
  end
end
