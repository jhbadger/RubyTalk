# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # `ruby bin/rubytalk --selftest`
    #
    # Drives the real windows with real Tk widgets (no human needed): types into
    # panes, selects text, generates key and mouse events, clicks list rows,
    # invokes menu entries, and checks the results. It uses a throw-away
    # changes.rb in a temporary directory, never yours. Prints PASS/FAIL per
    # check and exits non-zero if anything failed.
    #
    # It cannot test things that need a person: right-click pop-up menus
    # (they block until dismissed), window placement, and Cmd-Q.
    class SelfTest
      CHECKS = %i[
        workspace_text_roundtrip print_it_and_selection do_it_selection_and_transcript
        current_line_without_selection key_binding_print_it transcript_window_receives_output
        error_opens_notifier inspector browser_navigation browser_accept_and_autosave
        browser_accept_by_key search_implementors_and_senders method_list_window
        implementors_key_binding edit_menu_invokes_command changes_file_replays window_icon mac_quit_hook syntax_highlighting
        interrupt_stops_a_runaway_do_it background_thread_output windows_from_a_do_it
        versions_window hierarchy_browser debugger class_comment test_runner find_and_replace
        auto_indent_and_brackets remembered_window_layout file_out_and_in tk_console_hidden graphics_window scrolling_list popup_menu text_editing
        explain_it_by_key spawn_method_window protocols_and_class_versions
      ].freeze

      def initialize(main)
        @main = main
        @results = []
      end

      # Returns the number of failed checks.
      def run
        update
        CHECKS.each { |name| run_check(name) }
        cleanup
        report
        @results.count { |_name, error| error }
      end

      private

      def run_check(name)
        send("check_#{name}")
        @results << [name, nil, nil]
      rescue Exception => e # rubocop:disable Lint/RescueException -- report every failure, never abort the run
        # What the Transcript said just before it failed: usually the real reason.
        @results << [name, e, Transcript.buffer.lines.last(6).map { |line| line.strip[0, 160] }.reject(&:empty?)]
      ensure
        update
      end

      def report
        out = $stdout
        out.puts
        out.puts "RubyTalk self-test (Ruby #{RUBY_VERSION}, Tk #{tk_version})"
        @results.each do |name, error, transcript|
          if error
            out.puts "  FAIL  #{name}: #{error.class}: #{error.message.lines.first.to_s.strip}"
            Array(error.backtrace).first(4).each { |line| out.puts "          #{line}" }
            Array(transcript).each { |line| out.puts "          transcript: #{line}" }
          else
            out.puts "  PASS  #{name}"
          end
        end
        failed = @results.count { |_name, error| error }
        out.puts "#{@results.size - failed} passed, #{failed} failed"
      end

      def tk_version
        Tk::TK_VERSION
      rescue StandardError
        '?'
      end

      # --- helpers ---------------------------------------------------------

      def update
        Tk.tk_call('update')
      end

      def generate(widget, pattern, *options)
        Tk.tk_call('event', 'generate', widget.path, pattern, *options.map { |option| option.to_s.dup })
        update
      end

      def ivar(object, name)
        object.instance_variable_get(name)
      end

      def list_size(list)
        Tk.tk_call(list.box.path, 'size').to_i
      end

      # Select row +index+ with Tk itself, then deliver the mouse release the way
      # a click would, so the real curselection and binding are exercised.
      def click(list, index)
        list.box.selection_clear(0, 'end')
        list.box.selection_set(index)
        generate(list.box, '<ButtonRelease-1>')
      end

      def click_value(list, value)
        index = ivar(list, :@values).index(value)
        assert(index, "#{value.inspect} not in list")
        click(list, index)
      end

      def assert(condition, message = 'assertion failed')
        raise message unless condition
      end

      def assert_equal(expected, actual, message = nil)
        return if expected == actual

        raise "#{message || 'values differ'}: expected #{expected.inspect}, got #{actual.inspect}"
      end

      def changes_path
        RubyTalk.changes.path
      end

      # The checks themselves are in self_test/*_checks.rb, in the order CHECKS runs them.

      def cleanup
        Object.send(:remove_const, :RtSelfTest) if defined?(::RtSelfTest)
      end
    end
  end
end

require_relative 'self_test/editor_checks'
require_relative 'self_test/browser_checks'
require_relative 'self_test/system_checks'
require_relative 'self_test/graphics_checks'
