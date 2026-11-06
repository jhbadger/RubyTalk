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
        auto_indent_and_brackets remembered_window_layout file_out_and_in tk_console_hidden graphics_window scrolling_list
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
        assert(GUI.windows.size > before && GUI.windows.last.is_a?(Debugger), 'no debugger opened')
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

      # Redefine a method twice, then open its Versions window: the list, the selected
      # version's text and a revert, with real widgets.
      def check_versions_window
        klass = ::RtSelfTest
        changes = RubyTalk.changes
        Compiler.accept("def hi\n  :v2\nend\n", klass: klass, changes: changes)
        Compiler.accept("def hi\n  :v3\nend\n", klass: klass, changes: changes)
        window = VersionsWindow.new(klass, :instance, 'hi')
        list = ivar(window, :@list)
        assert(list_size(list) >= 3, "expected current + two earlier versions, got #{list_size(list)}")
        click(list, 1)
        assert(window.code.contents.include?(':v2'), "the newest earlier version was not shown: #{window.code.contents.inspect}")
        window.send(:revert)
        assert_equal :v2, klass.new.hi
      end

      # Hierarchy mode of the browser, with real widgets: the list starts at BasicObject.
      def check_hierarchy_browser
        browser = Browser.open(::RtSelfTest, hierarchy: true)
        classes = ivar(browser, :@classes)
        assert(list_size(classes) >= 3, "expected BasicObject, Object, RtSelfTest; got #{list_size(classes)} rows")
        assert_equal 'BasicObject', Tk.tk_call(classes.box.path, 'get', 0).to_s
        assert(browser.code.contents.start_with?('class RtSelfTest'), 'the class was not selected')
      end

      # An error opens the debugger with the locals of the frame that raised, and the console
      # evaluates in that frame (a binding captured by TracePoint at the raise, kept alive
      # after the stack unwound).
      def check_debugger
        Workspace.new(text: 'dbg_value = 41; raise "selftest debugger"').editor.do_it
        debugger = GUI.windows.last
        assert(debugger.is_a?(Debugger), 'no debugger opened')
        variables = ivar(debugger, :@variables)
        rows = Array.new(list_size(variables)) { |i| Tk.tk_call(variables.box.path, 'get', i).to_s }
        assert(rows.any? { |row| row.start_with?('dbg_value = 41') }, "locals shown: #{rows.inspect}")
        debugger.console.set_contents('dbg_value + 1')
        debugger.console.print_it
        assert_equal 'dbg_value + 1 42', debugger.console.contents
      end

      # Edit the comment above a class that already existed, accept, and reopen the browser.
      def check_class_comment
        Object.const_set(:RtSelfDoc, Class.new)
        browser = Browser.open(::RtSelfDoc)
        browser.code.set_contents("# selftest doc\nclass RtSelfDoc < Object\nend\n")
        browser.code.accept
        assert_equal "# selftest doc\n", Reflection.class_comment(::RtSelfDoc)
        again = Browser.open(::RtSelfDoc)
        assert(again.code.contents.start_with?("# selftest doc\n"), 'a new browser did not show the comment')
      ensure
        Object.send(:remove_const, :RtSelfDoc) if Object.const_defined?(:RtSelfDoc)
      end

      # Define a class with a passing and a failing Minitest test, run them from the class (on the
      # worker thread, through real Minitest) and look at the results window.
      def check_test_runner
        changes = RubyTalk.changes
        TestRunner.load_minitest
        Compiler.accept("class RtSelfCalc\nend\n", changes: changes)
        Compiler.accept("class RtSelfCalcTest < Minitest::Test\nend\n", changes: changes)
        Compiler.accept("def test_passes\n  assert true\nend\n", klass: ::RtSelfCalcTest, changes: changes)
        Compiler.accept("def test_fails\n  assert_equal 1, 2\nend\n", klass: ::RtSelfCalcTest, changes: changes)
        GUI.run_tests_for(::RtSelfCalc)
        window = GUI.windows.last
        assert(window.is_a?(TestResultsWindow), 'no results window opened')
        assert_equal 2, list_size(ivar(window, :@list))
        bar = ivar(window, :@bar)
        assert_equal '1 of 2 tests failed', Tk.tk_call(bar.path, 'cget', '-text').to_s
      ensure
        %i[RtSelfCalcTest RtSelfCalc].each do |name|
          next unless Object.const_defined?(name)

          TestRunner.forget(Object.const_get(name))
          Object.send(:remove_const, name)
        end
      end

      # Cmd-F opens the bar; typing marks matches (real tags, byte-safe columns); Next steps; Replace All edits.
      def check_find_and_replace
        editor = Workspace.new(text: "foo é foo\nfoo").editor
        editor.focus
        update
        generate(editor.text, "<#{MODIFIER}-Key-f>")
        bar = editor.find_bar
        assert(bar.visible?, 'Cmd-F did not open the find bar')
        bar.find_var.value = 'foo'
        generate(bar.find_entry, '<KeyRelease>')
        tags_at = ->(index) { Tk.tk_call(editor.text.path, 'tag', 'names', index).to_s.split }
        assert(tags_at.call('1.6').include?('rt_find'), "the second foo (after a multi-byte character) is not marked: #{tags_at.call('1.6').inspect}")
        assert(tags_at.call('2.0').include?('rt_find'), 'a match on the second line is not marked')
        assert_equal 'foo', editor.send(:selected_text)
        bar.find(forward: true)
        assert_equal '1.6', Tk.tk_call(editor.text.path, 'index', 'sel.first').to_s
        bar.replace_var.value = 'baz'
        bar.replace_all
        assert_equal "baz é baz\nbaz", editor.contents
        generate(bar.find_entry, '<Escape>')
        assert(!bar.visible?, 'Escape did not close the bar')
      end

      # Return keeps the indentation, Tab inserts two spaces, a typed `end` lines up with its `def`, and
      # the bracket next to the cursor is marked: real key events on a real text widget.
      def check_auto_indent_and_brackets
        editor = Workspace.new(text: 'x').editor
        editor.focus # Tk sends generated key events to the focus window
        update
        path = editor.text.path
        cursor_at = ->(index) { Tk.tk_call(path, 'mark', 'set', 'insert', index) }

        editor.set_contents('def foo')
        cursor_at.call('end-1c')
        generate(editor.text, '<Return>')
        assert_equal "def foo\n  ", editor.contents

        editor.set_contents('x')
        cursor_at.call('end-1c')
        generate(editor.text, '<Tab>')
        assert_equal 'x  ', editor.contents

        editor.set_contents("def foo\n  if x\n    a\n    end")
        cursor_at.call('end-1c')
        generate(editor.text, '<KeyRelease>')
        assert_equal "def foo\n  if x\n    a\n  end", editor.contents

        editor.set_contents('foo(a)')
        cursor_at.call('1.6')
        generate(editor.text, '<KeyRelease>')
        tags_at = ->(index) { Tk.tk_call(path, 'tag', 'names', index).to_s.split }
        assert(tags_at.call('1.3').include?('rt_bracket'), "the opening bracket is not marked: #{tags_at.call('1.3').inspect}")
        assert(tags_at.call('1.5').include?('rt_bracket'), 'the closing bracket is not marked')
      end

      # A window's size and position are saved and the next window of its kind opens the same size. Uses
      # a temporary home so your real saved layout is never touched.
      def check_remembered_window_layout
        original_home = ENV['HOME']
        Dir.mktmpdir('rubytalk-home') do |home|
          ENV['HOME'] = home
          GUI.reset_layout_state
          first = Workspace.new(text: 'layout')
          Tk.tk_call('wm', 'geometry', first.window.path, '431x287+90+110')
          update
          GUI.save_layout
          saved = Preferences.layout['workspace']
          assert(saved&.start_with?('431x287'), "the layout was not saved: #{saved.inspect}")
          second = Workspace.new(text: 'again')
          update
          assert_equal '431x287', Tk.tk_call('wm', 'geometry', second.window.path).to_s[/\A\d+x\d+/]
        end
      ensure
        ENV['HOME'] = original_home
        GUI.reset_layout_state
      end

      # File a class out to plain Ruby, remove it, file the file back in: the class and its method return and
      # are recorded again. (The dialogs need a person; this uses explicit paths.)
      def check_file_out_and_in
        changes = RubyTalk.changes
        Compiler.accept("# Filed out in the self-test.\nclass RtSelfEx\nend\n", changes: changes)
        Compiler.accept("def hello\n  :hello\nend\n", klass: ::RtSelfEx, changes: changes)
        path = File.join(File.dirname(changes.path), 'rt_self_ex.rb')
        GUI.file_out_class(::RtSelfEx, path)
        text = File.read(path)
        assert(Source.syntax_error(text).nil?, 'the filed-out file is not valid Ruby')
        assert(text.include?('def hello'), 'the method is missing from the file')
        Compiler.remove_class(::RtSelfEx, changes)
        assert(!Object.const_defined?(:RtSelfEx), 'the class should be gone')
        summary = GUI.file_in(path)
        assert(summary&.ok?, "file in failed: #{summary&.errors.inspect}")
        assert_equal :hello, ::RtSelfEx.new.hello
        assert(changes.find_method('RtSelfEx', :instance, 'hello'), 'the method was not recorded as a change')
      ensure
        Object.send(:remove_const, :RtSelfEx) if Object.const_defined?(:RtSelfEx)
      end

      # Tk's own "Console" shell window must not be showing. Without a console the `console` command does
      # not exist, which is also fine. (Asks the console's own interpreter for its window state.)
      def check_tk_console_hidden
        state = begin
          Tk.tk_call('console', 'eval', 'wm state .').to_s
        rescue StandardError
          'none'
        end
        assert(%w[withdrawn none].include?(state), "Tk's Console window is showing (state: #{state})")
      end

      # The MVC framework on real Tk: open a window with a button, show it in a Tk canvas, and drive it with
      # genuine mouse events (the %x %y arguments of the bindings), checking the picture reaches Tk.
      def check_graphics_window
        model = GraphicsExamples::Counter.new
        view = StandardSystemView.new('Graphics self-test', model, Point.new(200, 80))
        view.add_subview(ButtonView.new('+', Rectangle.from(10, 10, 60, 30)) { model.increment })
        view.add_subview(StringView.new(model, Rectangle.from(90, 15, 100, 20)) { |counter| "n=#{counter.count}" })
        view.open
        win = GUI.windows.last
        assert(win.is_a?(GraphicsWindow), 'no graphics window opened')
        update
        assert_equal '200', Tk.tk_call('image', 'width', win.image).to_s
        assert_equal '80', Tk.tk_call('image', 'height', win.image).to_s

        generate(win.canvas, '<Motion>', '-x', 20, '-y', 20)
        generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 20)
        assert(view.subviews.first.pressed, 'the press at 20,20 did not reach the button (mouse bindings)')
        generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 20)
        assert_equal 1, model.count, 'releasing on the button did not run its action'
        ControlManager.instance.refresh_all
        assert(view.form[95, 20] && view.form.copy(Rectangle.from(90, 15, 100, 20)).to_ascii.join.include?('#'),
               'the count was not drawn into the window')

        generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 20)
        generate(win.canvas, '<B1-Motion>', '-x', 150, '-y', 70)
        assert(!view.subviews.first.pressed, 'dragging off did not un-press the button (drag bindings)')
        generate(win.canvas, '<ButtonRelease-1>', '-x', 150, '-y', 70)
        assert_equal 1, model.count, 'releasing off the button must not run it'
        view.close
        assert_equal '0', Tk.tk_call('winfo', 'exists', win.window.path).to_s, 'closing the view did not close its window'
      ensure
        view&.close if ControlManager.instance.windows.include?(view)
      end

      # A list longer than its window, on real Tk: the wheel, a press on the scroll bar, a click and the
      # arrow keys (which go to the clicked list wherever the pointer is).
      def check_scrolling_list
        view = StandardSystemView.new('Scrolling self-test', nil, Point.new(120, 64))
        list = view.add_subview(ListView.new(Array.new(40) { |i| "row #{i}" }, Rectangle.from(0, 0, 120, 64)))
        view.open
        win = GUI.windows.last
        win.canvas.focus
        update
        assert(list.scrollbar_visible?, 'a 40 row list in a 64 pixel window needs a scroll bar')

        generate(win.canvas, '<MouseWheel>', '-x', 20, '-y', 20, '-delta', -1)
        assert(list.top.positive?, "the wheel did not scroll the list (top is #{list.top})")
        generate(win.canvas, '<MouseWheel>', '-x', 20, '-y', 20, '-delta', 1)
        generate(win.canvas, '<ButtonPress-1>', '-x', 114, '-y', 60)
        generate(win.canvas, '<ButtonRelease-1>', '-x', 114, '-y', 60)
        assert(list.top > 20, "a press low on the scroll bar did not scroll there (top is #{list.top})")

        generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 8)
        generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 8)
        assert(list.selection, 'clicking a row did not select it')
        before = list.selection
        generate(win.canvas, '<Motion>', '-x', 114, '-y', 5)
        generate(win.canvas, '<KeyPress>', '-keysym', 'Down')
        assert_equal before + 1, list.selection
      ensure
        view&.close if ControlManager.instance.windows.include?(view)
      end

      def cleanup
        Object.send(:remove_const, :RtSelfTest) if defined?(::RtSelfTest)
      end
    end
  end
end
