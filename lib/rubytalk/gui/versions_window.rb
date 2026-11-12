# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # Versions of one method (or, with name nil, of a class definition or comment), newest first: the current definition, earlier ones kept in
    # changes.history, and the original library method if RubyTalk has overridden or
    # removed it. Select one to read it; tick the box to see what reverting to it would
    # change; "Revert" makes it the current definition (the one it replaces is kept, so a
    # revert can be undone).
    class VersionsWindow
      extend MainThreadNew

      attr_reader :code

      # +on_change+ is called after a successful revert so the opener can refresh.
      def initialize(klass, side, name, on_change: nil)
        @klass = klass
        @side = side
        @name = name&.to_s
        @on_change = on_change
        @changes = RubyTalk.changes
        @window = TkToplevel.new
        GUI.window_title(@window, "Versions of #{title}")
        GUI.place(@window, kind: :versions)
        build
        GUI.build_menubar(@window, -> { @code })
        GUI.windows << self
        reload
      end

      private

      def title
        return "#{Reflection.name_of(@klass)} (class definition)" unless @name

        "#{Reflection.name_of(@klass)}#{@side == :class ? '.' : '#'}#{@name}"
      end

      def build
        TkLabel.new(@window, text: "Versions of #{title} (newest first)", anchor: 'w')
               .pack(side: 'top', fill: 'x', padx: 6, pady: 4)
        panes = TkFrame.new(@window)
        panes.pack(side: 'top', fill: 'both', expand: 1)
        @list = SelectableList.new(panes, width: 38, height: 12) { |version| show(version) }
        @list.frame.pack(side: 'left', fill: 'y')
        @code = CodeEditor.new(panes, width: 76, height: 14, highlight: true,
                                      evaluator: ->(source) { Evaluator.evaluate(source, Evaluator.new_binding, file: 'versions') })
        @code.frame.pack(side: 'left', fill: 'both', expand: 1)
        build_buttons
      end

      def build_buttons
        @diff_var = TkVariable.new(0)
        bar = TkFrame.new(@window)
        bar.pack(side: 'top', fill: 'x', pady: 4)
        TkCheckButton.new(bar, text: 'Show what reverting to the selected version would change', variable: @diff_var,
                               command: proc { GUI.safely { show(@list.selected_value) } }).pack(side: 'left', padx: 6)
        TkButton.new(bar, text: 'Close', command: proc { @window.destroy }).pack(side: 'right', padx: 6)
        TkButton.new(bar, text: 'Revert to this version',
                          command: proc { GUI.safely { revert } }).pack(side: 'right')
        @status = TkLabel.new(@window, text: +'', anchor: 'w')
        @status.pack(side: 'top', fill: 'x', padx: 6)
      end

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      def reload
        @versions = Reflection.versions(@klass, @side, @name, @changes)
        @list.set(@versions, @versions.map(&:label))
        if @versions.empty?
          @code.highlighting = true
          @code.set_contents("# No earlier versions of #{title} are known.\n" \
                             "# Versions appear once you #{@name ? 'redefine or remove it' : 'change it'} with Accept.\n")
          status('Nothing to revert to.')
        else
          @list.select_index(0)
        end
      end

      def show_diff?
        @diff_var.value.to_s == '1'
      end

      def show(version)
        return unless version

        current = @versions.find { |candidate| candidate.kind == :current }
        if show_diff? && current && !version.equal?(current)
          show_difference(current.source, version.source)
          status('Lines marked - would be removed, + added, if you revert to this version.')
        else
          @code.highlighting = true
          @code.set_contents(version.source)
          status(version.kind == :current ? 'This is the current definition.' : 'Revert makes this the current definition.')
        end
      end

      # Show a diff in the code pane, in the palette's green and red, without Ruby colouring.
      def show_difference(from, to)
        @code.highlighting = false
        text = Diff.unified(from, to)
        @code.set_contents(text)
        palette = Highlighter::PALETTES.fetch(@code.palette_name || :light)
        path = @code.text.path
        { 'rt_diff_add' => [:string, '+ '], 'rt_diff_del' => [:regexp, '- '] }.each do |tag, (colour, prefix)|
          tag = tag.dup # hash-literal string keys are frozen; the tk gem mutates what it is given
          Tk.tk_call(path, 'tag', 'configure', tag, '-foreground', palette.fetch(colour).dup)
          ranges = text.lines.each_with_index.select { |line, _| line.start_with?(prefix) }
                       .flat_map { |_, index| ["#{index + 1}.0", "#{index + 1}.end"] }
          Tk.tk_call(path, 'tag', 'add', tag, *ranges) unless ranges.empty?
        end
      end

      def revert
        version = @list.selected_value
        return status('Select a version first.') unless version
        return status('That is already the current definition.') if version.kind == :current

        outcome = Compiler.revert(@klass, @side, @name, version, @changes)
        if outcome.ok
          @on_change&.call
          reload
          status(outcome.message)
        else
          status("Not reverted: #{outcome.message.to_s.lines.first.to_s.strip}")
          ::Transcript.show_cr(outcome.message)
        end
      end
    end
  end
end
