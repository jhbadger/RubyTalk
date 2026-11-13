# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    class SelfTest
      # Checks of the editing panes: do it / print it / inspect it, key bindings, menus, highlighting, find, indent.
      # Uses the helpers of SelfTest (update, generate, click, assert ...).
      module EditorChecks
        def check_workspace_text_roundtrip
          workspace = Workspace.new(text: "héllo ✓\nsecond")
          assert_equal "héllo ✓\nsecond", workspace.editor.contents
        end

        def check_print_it_and_selection
          editor = Workspace.new(text: '3 + 4').editor
          editor.print_it
          assert_equal '3 + 4 7', editor.contents
          assert_equal ' 7', editor.send(:selected_text), 'print it should select the inserted text'
        end

        def check_do_it_selection_and_transcript
          editor = Workspace.new(text: "Transcript.show_cr 'not me'\nTranscript.show_cr 'picked'").editor
          editor.text.tag_add('sel', '2.0', '2.end')
          before = Transcript.buffer.size
          editor.do_it
          assert_equal "picked\n", Transcript.buffer[before..]
        end

        def check_current_line_without_selection
          editor = Workspace.new(text: "Transcript.show_cr 'first'\nTranscript.show_cr 'second'").editor
          before = Transcript.buffer.size
          editor.do_it
          assert_equal "first\n", Transcript.buffer[before..], 'the cursor should start on line 1'
        end

        def check_key_binding_print_it
          editor = Workspace.new(text: '6 * 7').editor
          editor.focus
          update
          generate(editor.text, "<#{MODIFIER}-Key-p>")
          assert_equal '6 * 7 42', editor.contents
        end

        def check_transcript_window_receives_output
          Transcript.show_cr('selftest-marker')
          assert(@main.editor.contents.include?('selftest-marker'), 'Transcript text did not reach the window')
        end

        def check_error_opens_notifier
          editor = Workspace.new(text: '1 / 0').editor
          before = GUI.windows.size
          editor.do_it
          assert(GUI.windows.size > before && GUI.windows.last.is_a?(Debugger), 'no debugger opened')
        end

        def check_edit_menu_invokes_command
          workspace = Workspace.new(text: '1 + 1')
          menubar = Tk.tk_call(workspace.window.path, 'cget', '-menu').to_s
          edit = Tk.tk_call(menubar, 'entrycget', 'Edit', '-menu').to_s
          Tk.tk_call(edit, 'invoke', 'Print it')
          assert_equal '1 + 1 2', workspace.editor.contents
        end

        # Cmd-E on a selected word writes an explanation to the Transcript.
        def check_explain_it_by_key
          editor = Workspace.new(text: 'String').editor
          editor.text.tag_add('sel', '1.0', '1.end')
          editor.focus
          update
          generate(editor.text, "<#{MODIFIER}-Key-e>")
          assert(::Transcript.buffer.include?('String is a class'), 'Cmd-E did not explain the selected word')
          editor.text.tag_remove('sel', '1.0', 'end')
          Tk.tk_call(editor.text.path, 'mark', 'set', 'insert', '1.3') # inside the word, nothing selected
          assert(editor.explain_it.to_s.include?('String is a class'), 'the word at the cursor was not explained')
        end

        # Colours are Tk text tags named rt_<kind>. The first line has a two-byte
        # character (é) so this also proves the byte-to-character column conversion.
        def check_syntax_highlighting
          editor = Workspace.new(text: "é = :sym # ü\ndef foo; end").editor
          tags_at = ->(index) { Tk.tk_call(editor.text.path, 'tag', 'names', index).to_s.split }
          assert(tags_at.call('1.0').none? { |tag| tag.start_with?('rt_') }, 'a plain identifier should be uncoloured')
          assert(tags_at.call('1.4').include?('rt_symbol'), "symbol at 1.4: #{tags_at.call('1.4').inspect}")
          assert(tags_at.call('1.9').include?('rt_comment'), "comment at 1.9: #{tags_at.call('1.9').inspect}")
          assert(tags_at.call('2.0').include?('rt_keyword'), 'def should be a keyword')
          assert(tags_at.call('2.4').include?('rt_def_name'), 'foo should be a method name')
          editor.set_contents('x = 1') # recolouring replaces, not accumulates
          assert(tags_at.call('1.4').include?('rt_number'), 'a number after set_contents')
          assert(tags_at.call('1.0').none? { |tag| tag.start_with?('rt_') }, 'old colours were cleared')
        end

        # Cmd-F opens the bar; typing marks matches (real tags, byte-safe columns); Next steps; Replace All edits.
        def check_find_and_replace
          editor = Workspace.new(text: "foo é foo\nfoo").editor
          editor.focus
          update
          generate(editor.text, "<#{MODIFIER}-Key-f>")
          bar = editor.find_bar
          assert(bar.visible?, 'Cmd-F did not open the find bar')
          bar.find_var.value = 'foo'
          generate(bar.find_entry, '<KeyRelease>')
          tags_at = ->(index) { Tk.tk_call(editor.text.path, 'tag', 'names', index).to_s.split }
          assert(tags_at.call('1.6').include?('rt_find'), "the second foo (after a multi-byte character) is not marked: #{tags_at.call('1.6').inspect}")
          assert(tags_at.call('2.0').include?('rt_find'), 'a match on the second line is not marked')
          assert_equal 'foo', editor.send(:selected_text)
          bar.find(forward: true)
          assert_equal '1.6', Tk.tk_call(editor.text.path, 'index', 'sel.first').to_s
          bar.replace_var.value = 'baz'
          bar.replace_all
          assert_equal "baz é baz\nbaz", editor.contents
          generate(bar.find_entry, '<Escape>')
          assert(!bar.visible?, 'Escape did not close the bar')
        end

        # Return keeps the indentation, Tab inserts two spaces, a typed `end` lines up with its `def`, and
        # the bracket next to the cursor is marked: real key events on a real text widget.
        def check_auto_indent_and_brackets
          editor = Workspace.new(text: 'x').editor
          editor.focus # Tk sends generated key events to the focus window
          update
          path = editor.text.path
          cursor_at = ->(index) { Tk.tk_call(path, 'mark', 'set', 'insert', index) }

          editor.set_contents('def foo')
          cursor_at.call('end-1c')
          generate(editor.text, '<Return>')
          assert_equal "def foo\n  ", editor.contents

          editor.set_contents('x')
          cursor_at.call('end-1c')
          generate(editor.text, '<Tab>')
          assert_equal 'x  ', editor.contents

          editor.set_contents("def foo\n  if x\n    a\n    end")
          cursor_at.call('end-1c')
          generate(editor.text, '<KeyRelease>')
          assert_equal "def foo\n  if x\n    a\n  end", editor.contents

          editor.set_contents('foo(a)')
          cursor_at.call('1.6')
          generate(editor.text, '<KeyRelease>')
          tags_at = ->(index) { Tk.tk_call(path, 'tag', 'names', index).to_s.split }
          assert(tags_at.call('1.3').include?('rt_bracket'), "the opening bracket is not marked: #{tags_at.call('1.3').inspect}")
          assert(tags_at.call('1.5').include?('rt_bracket'), 'the closing bracket is not marked')
        end

        # A text field on real Tk: click to focus, type with real key events, shift-select, copy and paste through the
        # system clipboard with the Command (Control) key, then a double click selecting a word. Restores whatever
        # was on your clipboard afterwards.
        def check_text_editing
          saved = begin
            Tk.tk_call('clipboard', 'get').to_s
          rescue StandardError
            nil
          end
          view = StandardSystemView.new('Text self-test', nil, Point.new(240, 60))
          field = view.add_subview(TextView.new(nil, Rectangle.from(0, 0, 240, 60)))
          view.open
          win = GUI.windows.last
          win.canvas.focus
          update
          key = ->(keysym, *options) { generate(win.canvas, '<KeyPress>', '-keysym', keysym, *options) }

          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 20)
          generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 20)
          assert(field.focused, 'clicking the field did not give it the keyboard')
          %w[h e l l o].each { |letter| key.call(letter) }
          key.call('space')
          %w[w o r l d].each { |letter| key.call(letter) }
          assert_equal 'hello world', field.text.sub(/\s+/, ' '), "typing: #{field.text.inspect}"
          key.call('Return')
          key.call('Left', '-state', 1)
          assert(field.selection_range, 'shift-left did not select (the modifier state in the key binding)')
          key.call('BackSpace')
          assert_equal 'hello world', field.text.sub(/\s+/, ' ').strip

          generate(win.canvas, "<#{MODIFIER}-Key>", '-keysym', 'a')
          generate(win.canvas, "<#{MODIFIER}-Key>", '-keysym', 'c')
          copied = Tk.tk_call('clipboard', 'get').to_s
          assert(copied.start_with?('hello'), "copy did not reach the system clipboard (got #{copied.inspect})")
          key.call('Delete')
          assert_equal '', field.text
          generate(win.canvas, "<#{MODIFIER}-Key>", '-keysym', 'v')
          assert(field.text.start_with?('hello'), 'paste did not bring the text back')

          field.place_caret(0)
          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 8)
          generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 8)
          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 8)
          generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 8)
          assert_equal 'hello', field.selected_text, 'a double click should select the word'
        ensure
          if saved
            Tk.tk_call('clipboard', 'clear')
            Tk.tk_call('clipboard', 'append', '--', saved.dup)
          end
          view&.close if ControlManager.instance.windows.include?(view)
        end
      end

      include EditorChecks
    end
  end
end
