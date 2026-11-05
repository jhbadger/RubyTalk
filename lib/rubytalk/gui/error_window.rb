# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The Smalltalk "notifier": shown when a do it / print it raises. It lists
    # the error and its backtrace and can open an Inspector on the exception.
    # (There is no resumable debugger; the stack has already unwound.)
    class ErrorWindow
      def initialize(error)
        @error = error
        @window = TkToplevel.new
        first_line = error.message.to_s.lines.first.to_s.strip
        GUI.window_title(@window, "#{error.class}: #{first_line}"[0, 100])
        GUI.place(@window)

        TkLabel.new(@window, text: "#{error.class}: #{first_line}", anchor: 'w', justify: 'left',
                             wraplength: 640, foreground: 'red').pack(side: 'top', fill: 'x', padx: 8, pady: 6)

        frame, text = GUI.scrolled_text(@window, width: 90, height: 14)
        frame.pack(side: 'top', fill: 'both', expand: 1)
        text.insert('end', details.dup)

        buttons = TkFrame.new(@window)
        buttons.pack(side: 'bottom', fill: 'x', pady: 4)
        TkButton.new(buttons, text: 'Close', command: proc { @window.destroy }).pack(side: 'right', padx: 6)
        TkButton.new(buttons, text: 'Inspect exception',
                              command: proc { GUI.safely { Inspector.new(@error) } }).pack(side: 'right')
        GUI.windows << self
      end

      private

      def details
        trace = Evaluator.filter_backtrace(@error.backtrace || [])
        "#{@error.class}: #{@error.message}\n\n#{trace.join("\n")}\n"
      end
    end
  end
end
