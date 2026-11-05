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

    class << self
      # Keeps window objects alive for the life of the session.
      attr_reader :windows

      def start
        MainWindow.new
        install_mac_quit
        Tk.mainloop
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

      # Cmd-Q on macOS goes through Tk's own quit hook; route it to ours so the
      # changes file is saved. (Best effort: harmless if the alias is refused.)
      def install_mac_quit
        return unless MAC

        Tk.tk_call('interp', 'alias', '', '::tk::mac::Quit', '', proc { quit })
      rescue StandardError
        nil
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
