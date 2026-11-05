# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # Find and Replace under a code pane (Cmd-F). Typing in the Find box marks every match and
    # selects the first one from the cursor; Return / Next and Shift-Return / Prev move through them
    # (wrapping round); Match case and Regexp change how the pattern is read (in a regular
    # expression \1 .. \9 and \0 in the replacement stand for groups of the match); Replace
    # replaces the selected match and moves on; Replace All does every match as one undo step.
    # Escape closes the bar. The searching itself is in Finder.
    class FindBar
      attr_reader :find_var, :replace_var, :find_entry

      def initialize(editor)
        @editor = editor
        @text = editor.text
        @matches = []
        @visible = false
        @last_find = ''
        @find_var = TkVariable.new(+'')
        @replace_var = TkVariable.new(+'')
        @case_var = TkVariable.new(0)
        @regexp_var = TkVariable.new(0)
        build(editor.frame)
      end

      def visible?
        @visible
      end

      # Open the bar (text is prefilled with +prefill+ when it is a single line) and focus Find.
      def show(prefill = nil)
        @find_var.value = prefill.dup if prefill && !prefill.empty? && !prefill.include?("\n")
        unless @visible
          Tk.tk_call('pack', @bar.path, '-side', 'bottom', '-fill', 'x', '-before', @editor.text_frame.path)
          @visible = true
        end
        configure_marks
        refresh(jump: true)
        @find_entry.focus
        Tk.tk_call(@find_entry.path, 'selection', 'range', 0, 'end')
      end

      def hide
        return unless @visible

        Tk.tk_call('pack', 'forget', @bar.path)
        @visible = false
        clear_marks
        @text.focus
      end

      # Re-mark the matches after the text changed.
      def refresh_if_visible
        refresh if @visible
      end

      # Go to the next (or previous) match from the selection, wrapping round.
      def find(forward: true)
        refresh
        return if @matches.empty?

        first, last = selection_offsets
        match, wrapped = Finder.pick(@matches, forward ? last : first, forward: forward)
        select(match)
        status("#{count_text}#{' (wrapped)' if wrapped}")
      end

      # Replace the selected match and move to the next; with no match selected, just find one.
      def replace
        refresh
        return if @matches.empty?

        first, last = selection_offsets
        current = @matches.find { |match| match.first == first && match.last == last }
        return find(forward: true) unless current

        text = @editor.contents
        index = Finder.indexer(text)
        replacement = Finder.replacement(current, @replace_var.value.to_s, regexp: regexp?)
        @text.delete(index.call(current.first), index.call(current.last))
        @text.insert(index.call(current.first), replacement.dup)
        Tk.tk_call(@text.path, 'mark', 'set', 'insert', "#{index.call(current.first)}+#{replacement.size}c")
        @editor.rehighlight
        find(forward: true)
      end

      def replace_all
        refresh
        return if @matches.empty?

        text = @editor.contents
        index = Finder.indexer(text)
        template = @replace_var.value.to_s
        count = @matches.size
        Tk.tk_call(@text.path, 'edit', 'separator')
        # From the end, so the positions of the matches still to do are unaffected.
        @matches.reverse_each do |match|
          @text.delete(index.call(match.first), index.call(match.last))
          @text.insert(index.call(match.first), Finder.replacement(match, template, regexp: regexp?).dup)
        end
        Tk.tk_call(@text.path, 'edit', 'separator')
        @editor.rehighlight
        refresh
        status("Replaced #{count}")
      end

      private

      def build(parent)
        @bar = TkFrame.new(parent)
        find_row = TkFrame.new(@bar)
        find_row.pack(side: 'top', fill: 'x', pady: 1)
        TkLabel.new(find_row, text: 'Find').pack(side: 'left', padx: 4)
        @find_entry = TkEntry.new(find_row, textvariable: @find_var, width: 26)
        @find_entry.pack(side: 'left', padx: 2)
        @find_entry.bind('KeyRelease') { GUI.safely { refresh(jump: @find_var.value.to_s != @last_find) } }
        @find_entry.bind('Return') { GUI.safely { find(forward: true) } }
        @find_entry.bind('Shift-Return') { GUI.safely { find(forward: false) } }
        @find_entry.bind('Escape') { GUI.safely { hide } }
        button(find_row, 'Prev') { find(forward: false) }
        button(find_row, 'Next') { find(forward: true) }
        check(find_row, 'Match case', @case_var)
        check(find_row, 'Regexp', @regexp_var)
        TkButton.new(find_row, text: 'Close', command: proc { GUI.safely { hide } }).pack(side: 'right', padx: 4)

        replace_row = TkFrame.new(@bar)
        replace_row.pack(side: 'top', fill: 'x', pady: 1)
        TkLabel.new(replace_row, text: 'Replace').pack(side: 'left', padx: 4)
        replace_entry = TkEntry.new(replace_row, textvariable: @replace_var, width: 26)
        replace_entry.pack(side: 'left', padx: 2)
        replace_entry.bind('Return') { GUI.safely { replace } }
        replace_entry.bind('Escape') { GUI.safely { hide } }
        button(replace_row, 'Replace') { replace }
        button(replace_row, 'Replace All') { replace_all }
        @status = TkLabel.new(replace_row, text: +'', anchor: 'w')
        @status.pack(side: 'left', fill: 'x', expand: 1, padx: 8)
      end

      def button(row, label, &action)
        TkButton.new(row, text: label, command: proc { GUI.safely(&action) }).pack(side: 'left', padx: 2)
      end

      def check(row, label, variable)
        TkCheckButton.new(row, text: label, variable: variable,
                               command: proc { GUI.safely { refresh(jump: true) } }).pack(side: 'left', padx: 4)
      end

      def case_sensitive?
        @case_var.value.to_s == '1'
      end

      def regexp?
        @regexp_var.value.to_s == '1'
      end

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      def count_text
        count = @matches.size
        count.zero? ? 'No match' : "#{count} match#{'es' unless count == 1}"
      end

      # The find colour (light or dark), above the other tags but under the selection.
      def configure_marks
        palette = Highlighter::MARKS.fetch(GUI.dark_background?(@text) ? :dark : :light)
        Tk.tk_call(@text.path, 'tag', 'configure', 'rt_find', '-background', palette.fetch(:find).dup)
        Tk.tk_call(@text.path, 'tag', 'raise', 'sel')
      end

      def clear_marks
        Tk.tk_call(@text.path, 'tag', 'remove', 'rt_find', '1.0', 'end')
      end

      # Mark every match; with jump: select the first one at or after the selection (so typing more of
      # a word stays on the same match).
      def refresh(jump: false)
        pattern = @find_var.value.to_s
        @last_find = pattern.dup
        clear_marks
        @matches = []
        return status('') if pattern.empty?

        text = @editor.contents
        @matches = Finder.matches(text, pattern, case_sensitive: case_sensitive?, regexp: regexp?)
        index = Finder.indexer(text)
        ranges = @matches.first(MAX_MARKED).flat_map { |match| [index.call(match.first), index.call(match.last)] }
        Tk.tk_call(@text.path, 'tag', 'add', 'rt_find', *ranges) unless ranges.empty?
        status(count_text)
        return unless jump && !@matches.empty?

        first, = selection_offsets
        select(Finder.pick(@matches, first, forward: true).first)
      rescue Finder::Error => e
        @matches = []
        status("Invalid pattern: #{e.message.lines.first.to_s.strip}")
      end

      # Marking thousands of matches is slow in Tk and not useful on screen.
      MAX_MARKED = 1000

      def select(match)
        text = @editor.contents
        index = Finder.indexer(text)
        @text.tag_remove('sel', '1.0', 'end')
        @text.tag_add('sel', index.call(match.first), index.call(match.last))
        Tk.tk_call(@text.path, 'mark', 'set', 'insert', index.call(match.last))
        Tk.tk_call(@text.path, 'see', index.call(match.first))
      end

      # [start, end] of the selection in characters, or the cursor twice when nothing is selected.
      def selection_offsets
        [offset_at('sel.first'), offset_at('sel.last')]
      rescue StandardError
        cursor = offset_at('insert')
        [cursor, cursor]
      end

      def offset_at(index)
        Tk.tk_call(@text.path, 'count', '-chars', '1.0', index).to_i
      end
    end
  end
end
