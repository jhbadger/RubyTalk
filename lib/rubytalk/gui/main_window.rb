# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The main window: the Transcript. It is also an editor, so do it / print it /
    # inspect it work here too. Closing it quits (after saving changes).
    class MainWindow
      attr_reader :editor, :root

      def initialize
        @root = TkRoot.new
        GUI.window_title(@root, title)
        GUI.place(@root, x: 20, y: 30)
        scope = Evaluator.new_binding
        @editor = CodeEditor.new(@root, width: 90, height: 28, wrap: 'word',
                                        evaluator: ->(source) { Evaluator.evaluate(source, scope, file: 'transcript') })
        @editor.frame.pack(fill: 'both', expand: 1)
        @editor.text.insert('end', ::Transcript.buffer.dup)
        @listener = ::Transcript.add_listener { |chunk| show(chunk) }
        GUI.build_menubar(@root, -> { @editor })
        @root.protocol('WM_DELETE_WINDOW') { GUI.quit }
        GUI.windows << self
        banner
        @editor.focus
      end

      private

      # "RubyTalk: /folder/holding/changes.rb" so it is always clear which image this is.
      def title
        path = RubyTalk.changes&.path
        path ? "RubyTalk: #{File.dirname(path)}" : 'RubyTalk'
      end

      def show(chunk)
        if chunk == :clear
          @editor.text.delete('1.0', 'end')
        else
          @editor.text.insert('end', chunk.dup)
          @editor.text.see('end')
          GUI.pump
        end
      end

      def banner
        ::Transcript.show_cr("RubyTalk #{RubyTalk::VERSION} on Ruby #{RUBY_VERSION}")
        ::Transcript.show_cr("Select text, then #{MOD_LABEL}-D (do it), #{MOD_LABEL}-P (print it), " \
                             "#{MOD_LABEL}-I (inspect it), #{MOD_LABEL}-B (browse it). " \
                             'Right-click for a menu.')
        ::Transcript.show_cr("Changes file: #{RubyTalk.changes.path} (every accepted change is saved as you go)")
        ::Transcript.show_cr("Working directory: #{Dir.pwd}")
        ::Transcript.show_cr("Running code from: #{RubyTalk::LIB_DIR}")
        ::Transcript.cr
      end
    end
  end
end
