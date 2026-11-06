# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The system clipboard, for the Clipboard that text views cut, copy and paste with, so text moves
    # between RubyTalk and other programs. Tk does all the work; an empty clipboard is just "".
    module TkClipboard
      module_function

      def get
        GUI.on_main { Tk.tk_call('clipboard', 'get').to_s }
      rescue StandardError
        '' # Tk raises when the clipboard is empty or holds something that is not text
      end

      def set(text)
        GUI.on_main do
          Tk.tk_call('clipboard', 'clear')
          Tk.tk_call('clipboard', 'append', '--', text.to_s.dup) # '--': text starting with a dash is not an option
        end
        text
      rescue StandardError => e
        ::Transcript.show_cr("(could not use the clipboard: #{e.class}: #{e.message.lines.first.to_s.strip})")
        nil
      end
    end
  end
end
