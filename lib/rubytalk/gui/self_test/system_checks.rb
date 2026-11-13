# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    class SelfTest
      # Checks of the application around the windows: icon, quit hook, Stop, background threads, window layout, the Tk console.
      # Uses the helpers of SelfTest (update, generate, click, assert ...).
      module SystemChecks
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
      end

      include SystemChecks
    end
  end
end
