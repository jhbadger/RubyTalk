# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # Results of "Implementors of" / "Senders of": a list of methods on top, the
    # selected method's source below (editable; Accept recompiles it in place).
    # Double-click (or right-click > Browse) opens the System Browser there.
    class MethodList
      extend MainThreadNew

      attr_reader :code

      # rows: how tall the list of methods is (a spawned method needs only one).
      def initialize(title, hits, rows: 10)
        @hits = hits
        @changes = RubyTalk.changes
        @window = TkToplevel.new
        GUI.window_title(@window, "#{title} (#{hits.size})")
        GUI.place(@window, kind: :method_list)
        @list = SelectableList.new(@window, width: 72, height: rows) { |hit| hit_selected(hit) }
        @list.frame.pack(side: 'top', fill: 'x')
        @list.set(hits, hits.map(&:label))
        @list.box.bind('Double-Button-1') { GUI.safely { browse } }
        @list.context_menu([['Browse', -> { browse }], ['Spawn', -> { spawn }], ['Versions...', -> { versions }]])
        @status = TkLabel.new(@window, text: +'', anchor: 'w')
        @status.pack(side: 'top', fill: 'x', padx: 6)
        @code = CodeEditor.new(@window, width: 90, height: 16, on_accept: -> { accept }, highlight: true,
                                        scope: -> { [@list.selected_value&.klass, @list.selected_value&.side] },
                                        on_spawn: ->(text) { spawn(text) },
                                        evaluator: ->(source) { Evaluator.evaluate(source, Evaluator.new_binding, file: 'method list') })
        @code.frame.pack(side: 'top', fill: 'both', expand: 1)
        GUI.build_menubar(@window, -> { @code })
        GUI.windows << self
        if hits.empty?
          status('Nothing found.')
        else
          @list.select_index(0)
        end
      end

      private

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      def hit_selected(hit)
        return unless hit

        text = hit.source || Reflection.method_text(hit.klass, hit.side, hit.name, @changes)
        @code.set_contents(text)
        status(hit.label)
      end

      def accept
        hit = @list.selected_value
        return status('Select a method first.') unless hit

        outcome = Compiler.accept(@code.contents, klass: hit.klass, side: hit.side, changes: @changes)
        if outcome.ok
          status(outcome.message)
        else
          status("Not accepted: #{outcome.message.to_s.lines.first.to_s.strip}")
          ::Transcript.show_cr(outcome.message)
        end
      end

      def versions
        hit = @list.selected_value
        return unless hit&.name

        VersionsWindow.new(hit.klass, hit.side, hit.name, on_change: -> { hit_selected(@list.selected_value) })
      end

      def browse
        hit = @list.selected_value
        Browser.open(hit.klass, method: hit.name, side: hit.side) if hit
      end

      # The selected method in a window of its own, with +text+ (edits not yet accepted) if given.
      def spawn(text = nil)
        hit = @list.selected_value
        return status('Select a method first.') unless hit

        if hit.name
          GUI.spawn_method(hit.klass, hit.side, hit.name, text)
        else
          GUI.spawn_workspace(text || @code.contents) # a class-body statement has no method to recompile
        end
      end
    end
  end
end
