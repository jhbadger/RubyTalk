# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # What opens when a do it raises: the Smalltalk "notifier", with a limited debugger.
    #
    #   stack (top left)     the frames, innermost first (RubyTalk's own plumbing hidden)
    #   source (top right)   the code of the selected frame, its current line marked
    #   variables (bottom left)  self and the locals of the frame that raised; double-click to inspect
    #   console (bottom right)   evaluate in that frame: select text, Cmd-D / Cmd-P / Cmd-I
    #
    # "Edit Method" opens the browser on the failing method so it can be fixed in place;
    # "Run Again" evaluates the original do it again (a debugger cannot resume, the stack
    # has already unwound). Only the frame that raised has its locals: Ruby does not keep
    # the others, so for outer frames only the source is shown.
    class Debugger
      extend MainThreadNew

      attr_reader :console, :source

      def initialize(error, failure = nil)
        @error = error
        @failure = failure
        @changes = RubyTalk.changes
        @frames = Stack.frames(error, failure&.binding)
        @frame = nil
        @window = TkToplevel.new
        first_line = error.message.to_s.lines.first.to_s.strip
        GUI.window_title(@window, "#{error.class}: #{first_line}"[0, 100])
        GUI.place(@window, kind: :debugger)
        build(first_line)
        GUI.build_menubar(@window, -> { @console })
        GUI.windows << self
        show_frames
      end

      private

      def build(first_line)
        TkLabel.new(@window, text: "#{@error.class}: #{first_line}", anchor: 'w', justify: 'left',
                             wraplength: 820, foreground: 'red').pack(side: 'top', fill: 'x', padx: 8, pady: 4)
        top = TkFrame.new(@window)
        top.pack(side: 'top', fill: 'both', expand: 1)
        @stack = SelectableList.new(top, width: 44, height: 8) { |frame| frame_selected(frame) }
        @stack.frame.pack(side: 'left', fill: 'y')
        @stack.box.bind('Double-Button-1') { GUI.safely { edit_method } }
        @source = CodeEditor.new(top, width: 84, height: 8, highlight: true, evaluator: console_evaluator)
        @source.frame.pack(side: 'left', fill: 'both', expand: 1)

        bottom = TkFrame.new(@window)
        bottom.pack(side: 'top', fill: 'both', expand: 1)
        @variables = SelectableList.new(bottom, width: 44, height: 8) { |_row| nil }
        @variables.frame.pack(side: 'left', fill: 'y')
        @variables.box.bind('Double-Button-1') { GUI.safely { inspect_variable } }
        @console = CodeEditor.new(bottom, width: 84, height: 8, highlight: true, evaluator: console_evaluator)
        @console.frame.pack(side: 'left', fill: 'both', expand: 1)
        @console.set_contents("# Evaluated in the selected frame: select text, then #{MOD_LABEL}-D / #{MOD_LABEL}-P / #{MOD_LABEL}-I\nself")

        build_buttons
      end

      def build_buttons
        bar = TkFrame.new(@window)
        bar.pack(side: 'top', fill: 'x', pady: 4)
        @status = TkLabel.new(bar, text: +'', anchor: 'w')
        @status.pack(side: 'left', fill: 'x', expand: 1, padx: 8)
        TkButton.new(bar, text: 'Close', command: proc { @window.destroy }).pack(side: 'right', padx: 4)
        TkButton.new(bar, text: 'Inspect Exception',
                          command: proc { GUI.safely { Inspector.new(@error) } }).pack(side: 'right')
        TkButton.new(bar, text: 'Run Again', command: proc { GUI.safely { run_again } }).pack(side: 'right')
        TkButton.new(bar, text: 'Edit Method', command: proc { GUI.safely { edit_method } }).pack(side: 'right')
      end

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      # Evaluate in the selected frame's binding; with none, in the one that raised, else a fresh one.
      def console_evaluator
        ->(source) { Evaluator.evaluate(source, current_binding, file: 'debugger') }
      end

      def current_binding
        @frame&.binding || @failure&.binding || (@fallback ||= Evaluator.new_binding)
      end

      def show_frames
        labels = @frames.each_with_index.map { |frame, index| "#{index}  #{frame}" }
        @stack.set(@frames, labels)
        if @frames.empty?
          @source.set_contents("# No stack is available for this error.\n")
          status('No frames.')
        else
          first = @frames.find(&:binding) || @frames.first
          @stack.select_index(@frames.index(first))
        end
      end

      def frame_selected(frame)
        return unless frame

        @frame = frame
        show_source(frame)
        rows = Stack.variables(frame.binding)
        @variables.set(rows, rows.map { |name, value| "#{name} = #{GUI.print_string(value)}"[0, 120] })
        status(frame.binding ? "#{frame.path}:#{frame.lineno}" : "#{frame.path}:#{frame.lineno} (locals are only kept for the frame that raised)")
      end

      def show_source(frame)
        text, line, = Stack.source_view(frame, @failure&.source, @changes)
        @source.set_contents(text)
        mark_line(line) if line
      end

      # Colour the line the frame is on and scroll to it.
      def mark_line(line)
        palette = Highlighter::MARKS.fetch(@source.palette_name || :light)
        path = @source.text.path
        Tk.tk_call(path, 'tag', 'configure', 'rt_current_line', '-background', palette.fetch(:current_line).dup)
        Tk.tk_call(path, 'tag', 'add', 'rt_current_line', "#{line}.0", "#{line}.end")
        Tk.tk_call(path, 'see', "#{line}.0")
      end

      def inspect_variable
        row = @variables.selected_value
        Inspector.new(row[1]) if row
      end

      def edit_method
        target = Stack.method_target(@frame || @frames.first, @changes) if @frame || @frames.first
        return status('No method to edit for this frame.') unless target

        klass, side, name = target
        Browser.open(klass, method: name, side: side)
      end

      def run_again
        rerun = @failure&.rerun or return status('This cannot be run again.')

        result = rerun.call
        @window.destroy
        if result.ok
          ::Transcript.show_cr("Run again: #{GUI.print_string(result.value)}")
        else
          GUI.notify_error(result.error, result.failure)
        end
      end
    end
  end
end
