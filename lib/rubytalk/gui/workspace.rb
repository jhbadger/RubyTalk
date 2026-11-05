# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # A Workspace: a free-form editor with its own temporaries. Variables
    # assigned in one do it are visible to the next, as in a Smalltalk workspace.
    class Workspace
      extend MainThreadNew

      def self.sample
        <<~TEXT
          # Select some text and press #{MOD_LABEL}-D (do it), #{MOD_LABEL}-P (print it) or #{MOD_LABEL}-I (inspect it).
          # With nothing selected, the current line is used.
          Transcript.show_cr 'Hello from RubyTalk'
          total = (1..10).sum
          total * 2
          [3, 1, 2].sort
        TEXT
      end

      attr_reader :editor, :window

      def initialize(text: nil, title: 'Workspace')
        @window = TkToplevel.new
        GUI.window_title(@window, title)
        GUI.place(@window, kind: :workspace)
        scope = Evaluator.new_binding
        @editor = CodeEditor.new(@window, width: 80, height: 20, highlight: true,
                                          evaluator: ->(source) { Evaluator.evaluate(source, scope, file: 'workspace') })
        @editor.frame.pack(fill: 'both', expand: 1)
        @editor.set_contents(text || self.class.sample)
        GUI.build_menubar(@window, -> { @editor })
        GUI.windows << self
        @editor.focus
      end
    end
  end
end
