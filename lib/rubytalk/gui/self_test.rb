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
        @results << [name, nil]
      rescue Exception => e # rubocop:disable Lint/RescueException -- report every failure, never abort the run
        @results << [name, e]
      ensure
        update
      end

      def report
        out = $stdout
        out.puts
        out.puts "RubyTalk self-test (Ruby #{RUBY_VERSION}, Tk #{tk_version})"
        @results.each do |name, error|
          if error
            out.puts "  FAIL  #{name}: #{error.class}: #{error.message.lines.first.to_s.strip}"
            Array(error.backtrace).first(4).each { |line| out.puts "          #{line}" }
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

      def generate(widget, pattern)
        Tk.tk_call('event', 'generate', widget.path, pattern)
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

      # --- checks ------------------------------------------------------------

      def check_workspace_text_roundtrip
        workspace = Workspace.new(text: "héllo ✓\nsecond")
        assert_equal "héllo ✓\nsecond", workspace.editor.contents
      end

      def check_print_it_and_selection
        editor = Workspace.new(text: '3 + 4').editor
        editor.print_it
        assert_equal '3 + 4 7', editor.contents
        assert_equal ' 7', editor.send(:selected_text), 'print it should select the inserted text'
      end

      def check_do_it_selection_and_transcript
        editor = Workspace.new(text: "Transcript.show_cr 'not me'\nTranscript.show_cr 'picked'").editor
        editor.text.tag_add('sel', '2.0', '2.end')
        before = Transcript.buffer.size
        editor.do_it
        assert_equal "picked\n", Transcript.buffer[before..]
      end

      def check_current_line_without_selection
        editor = Workspace.new(text: "Transcript.show_cr 'first'\nTranscript.show_cr 'second'").editor
        before = Transcript.buffer.size
        editor.do_it
        assert_equal "first\n", Transcript.buffer[before..], 'the cursor should start on line 1'
      end

      def check_key_binding_print_it
        editor = Workspace.new(text: '6 * 7').editor
        editor.focus
        update
        generate(editor.text, "<#{MODIFIER}-Key-p>")
        assert_equal '6 * 7 42', editor.contents
      end

      def check_transcript_window_receives_output
        Transcript.show_cr('selftest-marker')
        assert(@main.editor.contents.include?('selftest-marker'), 'Transcript text did not reach the window')
      end

      def check_error_opens_notifier
        editor = Workspace.new(text: '1 / 0').editor
        before = GUI.windows.size
        editor.do_it
        assert(GUI.windows.size > before && GUI.windows.last.is_a?(ErrorWindow), 'no error window opened')
      end

      def check_inspector
        editor = Workspace.new(text: '[10, 20, {a: 1}]').editor
        editor.inspect_it
        inspector = GUI.windows.last
        assert(inspector.is_a?(Inspector), 'no inspector opened')
        list = ivar(inspector, :@list)
        assert_equal 4, list_size(list)
        click(list, 1)
        assert_equal '10', ivar(inspector, :@value).contents
      end

      def check_browser_navigation
        browser = Browser.open(String)
        assert(browser.code.contents.start_with?('class String'), 'class definition not shown')
        protocols = ivar(browser, :@protocols)
        assert_equal 4, list_size(protocols)
        click(protocols, 1)
        methods = ivar(browser, :@methods)
        assert(list_size(methods) > 50, 'method list did not fill')
        click_value(methods, :upcase)
        assert(browser.code.contents.include?('implemented in C'), 'method description not shown')
        generate(ivar(browser, :@classes).box, '<KeyRelease>') # must not raise
      end

      def check_browser_accept_and_autosave
        browser = Browser.open
        categories = ivar(browser, :@categories)
        click_value(categories, Reflection::USER)
        assert_equal Reflection.new_class_template, browser.code.contents
        browser.code.set_contents("class RtSelfTest\nend\n")
        browser.code.accept
        assert(defined?(::RtSelfTest), 'class was not created')
        click(ivar(browser, :@protocols), 0)
        browser.code.set_contents("def hi\n  rt_selftest_marker\nend\n")
        browser.code.accept
        assert(::RtSelfTest.method_defined?(:hi), 'method was not defined')
        assert_equal "def hi\n  rt_selftest_marker\nend\n", browser.code.contents
        text = File.read(changes_path)
        assert(text.include?('target=RtSelfTest') && text.include?('key=hi'), 'autosave did not write changes.rb')
      end

      def check_browser_accept_by_key
        browser = Browser.open(::RtSelfTest)
        click(ivar(browser, :@protocols), 0)
        browser.code.set_contents("def other\n  :other\nend\n")
        browser.code.focus
        update
        generate(browser.code.text, "<#{MODIFIER}-Key-s>")
        assert_equal :other, ::RtSelfTest.new.other
      end

      def check_search_implementors_and_senders
        assert(Search.implementors('upcase').any? { |hit| hit.klass == String }, 'String#upcase not found')
        senders = Search.senders('rt_selftest_marker')
        assert(senders.any? { |hit| hit.label == 'RtSelfTest#hi' }, "senders: #{senders.map(&:label).inspect}")
      end

      def check_method_list_window
        GUI.show_method_list(:implementors, 'upcase')
        window = GUI.windows.last
        assert(window.is_a?(MethodList), 'no method list opened')
        click(ivar(window, :@list), 0)
        assert(window.code.contents.include?('upcase'), 'method source not shown')
      end

      def check_implementors_key_binding
        editor = Workspace.new(text: 'upcase').editor
        editor.text.tag_add('sel', '1.0', '1.end')
        editor.focus
        update
        generate(editor.text, "<#{MODIFIER}-Key-m>")
        assert(GUI.windows.last.is_a?(MethodList), 'Cmd-M did not open a method list')
      end

      def check_edit_menu_invokes_command
        workspace = Workspace.new(text: '1 + 1')
        menubar = Tk.tk_call(workspace.window.path, 'cget', '-menu').to_s
        edit = Tk.tk_call(menubar, 'entrycget', 'Edit', '-menu').to_s
        Tk.tk_call(edit, 'invoke', 'Print it')
        assert_equal '1 + 1 2', workspace.editor.contents
      end

      # Replays what this run wrote into a fresh ChangeSet, in this process.
      def check_changes_file_replays
        entries = ChangeSet.parse(File.read(changes_path)).compact
        assert(entries.any? { |e| e.kind == :class && e.target == 'RtSelfTest' }, 'class entry missing')
        assert(entries.any? { |e| e.kind == :method && e.key == 'other' }, 'method entry missing')
      end

      # The icon is built in code and handed to Tk as a base64 PNG.
      def check_window_icon
        image = GUI.icon_image
        assert(image && !image.empty?, 'no icon image was created (see the Transcript for the reason)')
        assert_equal 'photo', Tk.tk_call('image', 'type', image).to_s
        assert_equal 128, Tk.tk_call('image', 'width', image).to_i
      end

      # Cmd-Q and the app menu's Quit call ::tk::mac::Quit. Prove the hook reaches
      # the window-close handler through real Tcl and Ruby/Tk callbacks (the old
      # alias-based hook failed with "invalid command name rb_out c000NN"). The
      # handler is swapped for a probe and then restored; nothing is quit.
      def check_mac_quit_hook
        return unless MAC

        called = false
        @main.root.protocol('WM_DELETE_WINDOW') { called = true }
        begin
          Tk.tk_call('::tk::mac::Quit')
        ensure
          @main.root.protocol('WM_DELETE_WINDOW') { GUI.quit }
        end
        assert(called, '::tk::mac::Quit did not reach the window-close handler')
      end

      # Colours are Tk text tags named rt_<kind>. The first line has a two-byte
      # character (é) so this also proves the byte-to-character column conversion.
      def check_syntax_highlighting
        editor = Workspace.new(text: "é = :sym # ü\ndef foo; end").editor
        tags_at = ->(index) { Tk.tk_call(editor.text.path, 'tag', 'names', index).to_s.split }
        assert(tags_at.call('1.0').none? { |tag| tag.start_with?('rt_') }, 'a plain identifier should be uncoloured')
        assert(tags_at.call('1.4').include?('rt_symbol'), "symbol at 1.4: #{tags_at.call('1.4').inspect}")
        assert(tags_at.call('1.9').include?('rt_comment'), "comment at 1.9: #{tags_at.call('1.9').inspect}")
        assert(tags_at.call('2.0').include?('rt_keyword'), 'def should be a keyword')
        assert(tags_at.call('2.4').include?('rt_def_name'), 'foo should be a method name')
        editor.set_contents('x = 1') # recolouring replaces, not accumulates
        assert(tags_at.call('1.4').include?('rt_number'), 'a number after set_contents')
        assert(tags_at.call('1.0').none? { |tag| tag.start_with?('rt_') }, 'old colours were cleared')
      end

      # Run `loop {}` as a do it; a timer presses Stop while the main thread is pumping
      # events. Proves the worker thread, the event pump, Cmd-. handling and the
      # interrupt all work together on real Tk.
      def check_interrupt_stops_a_runaway_do_it
        editor = Workspace.new(text: 'loop {}').editor
        TkTimer.new(150, 1, proc { GUI.interrupt }).start
        # Safety net so a failure is reported instead of hanging the self-test: if the
        # timer never delivers Stop, a plain Ruby thread does, and the check fails.
        rescued = false
        watchdog = Thread.new do
          sleep 8
          rescued = true
          Evaluator.stop
          sleep 1
          Evaluator.stop
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        editor.do_it
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        watchdog.kill
        assert(!rescued, "the Stop timer never fired (the watchdog stopped it after #{elapsed.round(1)}s)")
        assert(Transcript.buffer.include?('Interrupted.'), 'no "Interrupted." in the Transcript')
        assert(!Evaluator.busy?, 'still marked busy')
      end

      # A thread started by a do it prints to the Transcript: Tk must only be touched
      # from the main thread, so the text is handed over.
      def check_background_thread_output
        Workspace.new(text: "Thread.new { Transcript.show_cr 'selftest-background' }.join").editor.do_it
        update
        assert(@main.editor.contents.include?('selftest-background'), 'output from another thread did not arrive')
      end

      # `Inspector.new(x)` written inside a do it runs on the worker thread.
      def check_windows_from_a_do_it
        editor = Workspace.new(text: 'RubyTalk::GUI::Inspector.new([1, 2]); :ok').editor
        editor.do_it
        assert(GUI.windows.last.is_a?(Inspector), 'the Inspector was not opened')
      end

      def cleanup
        Object.send(:remove_const, :RtSelfTest) if defined?(::RtSelfTest)
      end
    end
  end
end
