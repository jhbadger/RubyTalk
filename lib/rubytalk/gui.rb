# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

require 'tk'

module RubyTalk
  # The Tk user interface. All Tk-specific plumbing lives in this module and in
  # the small widget classes under gui/, so the rest of RubyTalk stays testable
  # without a display.
  module GUI
    MAC = RUBY_PLATFORM.include?('darwin')
    # Modifier for do it / print it / inspect it / accept key bindings.
    MODIFIER = MAC ? 'Command' : 'Control'
    MOD_LABEL = MAC ? 'Cmd' : 'Ctrl'
    MAX_PRINT = 100_000

    @windows = []
    @last_pump = 0.0
    @cascade = 0

    class << self
      # Keeps window objects alive for the life of the session.
      attr_reader :windows

      # Opens the Transcript, a System Browser and a Workspace, then runs Tk.
      # With selftest: true, runs the built-in checks against real widgets and
      # exits instead (see SelfTest).
      def start(selftest: false)
        main = MainWindow.new
        set_window_icon
        install_mac_quit
        if selftest
          failures = SelfTest.new(main).run
          begin
            Tk.root.destroy
          rescue StandardError
            nil
          end
          exit(failures.zero? ? 0 : 1)
        end
        Tk.tk_call('wm', 'deiconify', '.') # it was withdrawn while the folder chooser was up
        Browser.open
        Workspace.new
        Tk.mainloop
      end

      # The Tk image used as the icon for every window (and, on macOS, the Dock
      # icon even when RubyTalk is not run from the app bundle). nil if Tk refused it.
      attr_reader :icon_image

      # Stagger new windows so they do not stack exactly on top of each other.
      def place(window, x: nil, y: nil)
        unless x
          step = @cascade % 8
          @cascade += 1
          x = 70 + (step * 28)
          y = 80 + (step * 28)
        end
        Tk.tk_call('wm', 'geometry', window.path, "+#{x}+#{y}")
      end

      def set_window_icon
        @icon_image = Tk.tk_call('image', 'create', 'photo', '-data', Icon.png_base64(128).dup).to_s
        Tk.tk_call('wm', 'iconphoto', '.', '-default', @icon_image)
      rescue StandardError => e
        @icon_image = nil
        ::Transcript.show_cr("(window icon not set: #{e.class}: #{e.message.lines.first.to_s.strip})")
      end

      # macOS routes Cmd-Q and the application menu's Quit through the Tcl command
      # ::tk::mac::Quit (default: exit, which would skip saving). Redefine it to run
      # the Transcript window's close handler, so every way of quitting takes the
      # same path: GUI.quit. (A Tcl alias to a Ruby callback does not work: the
      # callback handle "rb_out c000NN" is two words, not a command name.)
      def define_quit_hook
        Tk.tk_call('proc', '::tk::mac::Quit', '', 'eval [wm protocol . WM_DELETE_WINDOW]')
      end

      # Ask which folder holds this image's changes.rb (the app's default). The
      # chooser starts in the folder used last time. Returns nil if cancelled.
      def choose_directory
        Tk.tk_call('wm', 'withdraw', '.')
        set_window_icon
        chosen = Tk.tk_call('tk_chooseDirectory', '-initialdir', Preferences.last_directory.dup,
                            '-title', 'RubyTalk: choose the folder for changes.rb').to_s
        return nil if chosen.empty?

        Preferences.remember_directory(chosen)
        chosen
      end

      # Open Finder on the changes file (or its folder if it has not been written yet).
      def reveal_changes_file
        path = RubyTalk.changes&.path or return
        target = File.exist?(path) ? ['open', '-R', path] : ['open', File.dirname(path)]
        system(*target)
      end

      # Draw anything pending now (used before slow searches).
      def flush
        Tk.tk_call('update', 'idletasks')
      rescue StandardError
        nil
      end

      # Run an implementors/senders search and show the results in a Method List.
      def show_method_list(kind, selector)
        ::Transcript.show_cr("Searching for #{kind} of #{selector}...")
        flush
        hits = kind == :senders ? Search.senders(selector) : Search.implementors(selector)
        MethodList.new("#{kind.to_s.capitalize} of #{selector}", hits)
      end

      # Run a callback body; never let an exception reach Tk's event loop.
      def safely
        yield
      rescue StandardError, ScriptError => e
        ::Transcript.show_cr("[RubyTalk internal error] #{Evaluator.format_error(e, filter: false)}")
        nil
      end

      # printString: what "print it" inserts.
      def print_string(value)
        text = value.inspect
        text.size > MAX_PRINT ? "#{text[0, MAX_PRINT]}... (truncated)" : text
      rescue StandardError => e
        "#<#{value.class}: inspect failed (#{e.class}: #{e.message})>"
      end

      # Flush pending drawing so Transcript output appears during long doits.
      def pump
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if now - @last_pump < 0.05

        @last_pump = now
        Tk.tk_call('update', 'idletasks')
      rescue StandardError
        nil
      end

      def notify_error(error)
        return if error.is_a?(SystemExit)

        ErrorWindow.new(error)
      end

      def quit
        RubyTalk.save_changes
        Tk.root.destroy
      rescue StandardError
        exit
      end

      def confirm(message)
        Tk.tk_call('tk_messageBox', '-type', 'yesno', '-icon', 'warning', '-message', message).to_s == 'yes'
      end

      def window_title(window, title)
        Tk.tk_call('wm', 'title', window.path, title)
      end

      # Pop a menu up at the mouse pointer.
      def popup(menu)
        x = Tk.tk_call('winfo', 'pointerx', '.').to_i
        y = Tk.tk_call('winfo', 'pointery', '.').to_i
        Tk.tk_call('tk_popup', menu.path, x, y)
      end

      def generate_event(name)
        focus = Tk.tk_call('focus').to_s
        Tk.tk_call('event', 'generate', focus, "<<#{name}>>") unless focus.empty?
      end

      # A text widget with scrollbars. Returns [frame, text].
      def scrolled_text(parent, width:, height:, wrap: 'none')
        frame = TkFrame.new(parent)
        text = TkText.new(frame, width: width, height: height, wrap: wrap, undo: 1, font: 'TkFixedFont')
        ybar = TkScrollbar.new(frame)
        text.yscrollbar(ybar)
        ybar.pack(side: 'right', fill: 'y')
        if wrap == 'none'
          xbar = TkScrollbar.new(frame, orient: 'horizontal')
          text.xscrollbar(xbar)
          xbar.pack(side: 'bottom', fill: 'x')
        end
        text.pack(side: 'left', fill: 'both', expand: 1)
        [frame, text]
      end

      def add_item(menu, label, accelerator = nil, &action)
        options = { label: label, command: proc { safely(&action) } }
        options[:accelerator] = accelerator if accelerator
        menu.add('command', options)
      end

      # The menu bar shared by every window. +provider+ returns the CodeEditor
      # the Edit menu should act on.
      def build_menubar(window, provider)
        bar = TkMenu.new(window, tearoff: false)
        add_system_menu(bar)
        add_edit_menu(bar, provider)
        window.configure(menu: bar)
        bar
      end

      private

      def add_system_menu(bar)
        system = TkMenu.new(bar, tearoff: false)
        bar.add('cascade', label: 'System', menu: system)
        add_item(system, 'Open Workspace') { Workspace.new }
        add_item(system, 'Open System Browser') { Browser.open }
        add_item(system, 'Show Transcript') do
          Tk.tk_call('wm', 'deiconify', '.')
          Tk.tk_call('raise', '.')
        end
        add_item(system, 'Show Changes (copy)') do
          Workspace.new(text: RubyTalk.changes.to_text, title: 'Changes (a copy: edits here are not saved)')
        end
        add_item(system, 'Reveal Changes File in Finder') { reveal_changes_file } if MAC
        add_item(system, 'Save Changes Now') do
          path = RubyTalk.save_changes
          ::Transcript.show_cr(path ? "Changes saved to #{path}" : 'No unsaved changes.')
        end
        add_item(system, 'Clear Transcript') { ::Transcript.clear }
        system.add('separator')
        add_item(system, 'Quit', "#{MOD_LABEL}-Q") { quit }
      end

      def add_edit_menu(bar, provider)
        edit = TkMenu.new(bar, tearoff: false)
        bar.add('cascade', label: 'Edit', menu: edit)
        add_item(edit, 'Do it', "#{MOD_LABEL}-D") { provider.call&.do_it }
        add_item(edit, 'Print it', "#{MOD_LABEL}-P") { provider.call&.print_it }
        add_item(edit, 'Inspect it', "#{MOD_LABEL}-I") { provider.call&.inspect_it }
        add_item(edit, 'Browse it', "#{MOD_LABEL}-B") { provider.call&.browse_it }
        add_item(edit, 'Implementors of it', "#{MOD_LABEL}-M") { provider.call&.implementors_of_it }
        add_item(edit, 'Senders of it', "#{MOD_LABEL}-N") { provider.call&.senders_of_it }
        if provider.call&.can_accept?
          edit.add('separator')
          add_item(edit, 'Accept', "#{MOD_LABEL}-S") { provider.call&.accept }
        end
        edit.add('separator')
        add_item(edit, 'Cut') { generate_event('Cut') }
        add_item(edit, 'Copy') { generate_event('Copy') }
        add_item(edit, 'Paste') { generate_event('Paste') }
        add_item(edit, 'Select All') { generate_event('SelectAll') }
      end

      def install_mac_quit
        define_quit_hook if MAC
      rescue StandardError => e
        ::Transcript.show_cr("(Cmd-Q hook not installed: #{e.class}: #{e.message.lines.first.to_s.strip})")
      end
    end
  end
end

require_relative 'gui/selectable_list'
require_relative 'gui/code_editor'
require_relative 'gui/error_window'
require_relative 'gui/main_window'
require_relative 'gui/workspace'
require_relative 'gui/browser'
require_relative 'gui/inspector'
require_relative 'gui/method_list'
require_relative 'gui/self_test'
