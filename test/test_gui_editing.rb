# frozen_string_literal: true

# Auto-indent, bracket matching, find and replace in the code panes.
#   ruby test/test_gui_editing.rb

require_relative 'support/gui_case'

class GuiEditingTest < GuiCase
  # A code pane with the cursor at +offset+ (default: the very end).
  def code_pane(text, offset = nil)
    editor = GUI::Workspace.new(text: text).editor
    editor.text.insert_offset = offset || text.size
    editor
  end

  def find_fixture(text)
    editor = GUI::Workspace.new(text: text).editor
    editor.show_find
    [editor, editor.find_bar]
  end

  def type_find(bar, pattern)
    bar.find_var.value = +pattern
    bar.find_entry.fire('KeyRelease')
  end

  def selection_start(editor)
    tk(editor.text.path, 'count', '-chars', '1.0', 'sel.first').to_i
  end

  def marks(editor)
    editor.text.tag_store.fetch('rt_find', nil)
  end

  def find_status(bar)
    ivar(bar, :@status).options[:text]
  end

  # --- auto-indent and bracket matching -----------------------------------------


  def test_return_keeps_and_adds_indentation
    {
      'def foo' => "def foo\n  ",
      '  if x' => "  if x\n    ",
      '  a = 1' => "  a = 1\n  ",
      'items.each do |x|' => "items.each do |x|\n  ",
      '  end' => "  end\n  "
    }.each do |text, expected|
      editor = code_pane(text)
      assert_equal :break, editor.text.fire('Return'), 'the default newline is suppressed'
      assert_equal expected, editor.contents, text.inspect
      assert_equal expected.size, editor.text.insert_offset, 'the cursor is on the new line, after the indentation'
    end
  end

  def test_return_in_the_middle_of_a_line_and_over_a_selection
    editor = code_pane('foo(a)', 4)
    editor.text.fire('Return')
    assert_equal "foo(\n  a)", editor.contents

    editor = code_pane('abc def', 3)
    editor.text.select_text('abc')
    editor.text.fire('Return')
    assert_equal "\n def", editor.contents, 'a selection is replaced, as Return normally does'
  end

  def test_tab_inserts_two_spaces
    editor = code_pane('x')
    assert_equal :break, editor.text.fire('Tab')
    assert_equal 'x  ', editor.contents
  end

  def test_typing_end_else_or_a_closer_lines_up_with_its_opener
    editor = code_pane("def foo\n  if x\n    a\n    end")
    editor.text.fire('KeyRelease')
    assert_equal "def foo\n  if x\n    a\n  end", editor.contents
    assert_equal editor.contents.size, editor.text.insert_offset, 'the cursor stays at the end of the line'

    editor = code_pane("def foo\n  if x\n    a\n    else")
    editor.text.fire('KeyRelease')
    assert_equal "def foo\n  if x\n    a\n  else", editor.contents

    editor = code_pane("h = {\n  a: 1\n  }")
    editor.text.fire('KeyRelease')
    assert_equal "h = {\n  a: 1\n}", editor.contents
  end

  def test_dedent_leaves_existing_code_and_other_lines_alone
    [
      ["def foo\n  a\n      end", nil],            # indented by hand: not the auto-indent position
      ["def foo\n  a\n  endless = 1", nil],        # not a closer
      ["def foo\n  a\n  when: 1", nil]
    ].each do |text, _|
      editor = code_pane(text)
      editor.text.fire('KeyRelease')
      assert_equal text, editor.contents, text.inspect
    end
    editor = code_pane("def foo\n  if x\n    a\n    end\nmore", 30) # cursor not at the end of that line
    before = editor.contents
    editor.text.fire('KeyRelease')
    assert_equal before, editor.contents
  end

  def test_the_bracket_next_to_the_cursor_is_marked_with_its_partner
    editor = code_pane('foo(a, [1])', 11)
    editor.text.fire('KeyRelease')
    names = ->(index) { editor.text.tag_command(['names', index]).split }
    assert_includes names.call('1.3'), 'rt_bracket'
    assert_includes names.call('1.10'), 'rt_bracket'
    refute_includes names.call('1.4'), 'rt_bracket'

    editor.text.insert_offset = 5 # not next to a bracket
    editor.text.fire('KeyRelease')
    assert_nil editor.text.tag_store.fetch('rt_bracket', nil), 'the marks go when the cursor moves away'

    editor.text.insert_offset = 4 # just after the opener, by clicking
    editor.text.fire('ButtonRelease-1')
    assert_includes names.call('1.10'), 'rt_bracket'

    unbalanced = code_pane('foo(a', 4)
    unbalanced.text.fire('KeyRelease')
    assert_nil unbalanced.text.tag_store.fetch('rt_bracket', nil), 'no partner, nothing to mark'
  end

  def test_the_transcript_and_find_entries_have_no_smart_editing
    main = GUI::MainWindow.new
    refute main.editor.text.bindings.key?('Return'), 'Return in the Transcript is untouched'
    refute main.editor.text.bindings.key?('Tab')
    main.editor.show_find
    refute main.editor.find_bar.find_entry.bindings.key?('Tab')
  end

  # --- find and replace ------------------------------------------------------







  def test_find_marks_every_match_and_selects_the_first
    editor, bar = find_fixture('alpha beta alpha')
    assert bar.visible?
    type_find(bar, 'alpha')
    assert_equal [[0, 5], [11, 16]], marks(editor)
    assert_equal 'alpha', editor.text.get('sel.first', 'sel.last')
    assert_equal 0, selection_start(editor)
    assert_equal '2 matches', find_status(bar)
    type_find(bar, 'beta')
    assert_equal [[6, 10]], marks(editor), 'the old marks are replaced'
    assert_equal 6, selection_start(editor)
    type_find(bar, 'nothing')
    assert_nil marks(editor)
    assert_equal 'No match', find_status(bar)
  end

  def test_find_next_and_previous_step_and_wrap
    editor, bar = find_fixture('a b a b a')
    type_find(bar, 'a')
    assert_equal 0, selection_start(editor)
    bar.find(forward: true)
    assert_equal 4, selection_start(editor)
    bar.find(forward: true)
    assert_equal 8, selection_start(editor)
    bar.find(forward: true)
    assert_equal 0, selection_start(editor)
    assert_match(/wrapped/, find_status(bar))
    bar.find(forward: false)
    assert_equal 8, selection_start(editor), 'backwards from the first wraps to the last'
    bar.find(forward: false)
    assert_equal 4, selection_start(editor)
  end

  def test_find_match_case_and_regexp_options
    editor, bar = find_fixture('Alpha alpha a1 a22')
    type_find(bar, 'alpha')
    assert_equal 2, marks(editor).size
    ivar(bar, :@case_var).value = +'1'
    bar.send(:refresh)
    assert_equal 1, marks(editor).size, 'match case'
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, 'a\d+')
    assert_equal 2, marks(editor).size, 'regexp'
    type_find(bar, '(')
    assert_match(/Invalid pattern/, find_status(bar))
    assert_nil marks(editor)
  end

  def test_find_prefills_from_the_selection
    editor = GUI::Workspace.new(text: 'one two three').editor
    editor.text.select_text('two')
    editor.show_find
    assert_equal 'two', editor.find_bar.find_var.value
    assert_equal [[4, 7]], marks(editor)
  end

  def test_replace_steps_through_matches
    editor, bar = find_fixture('foo bar foo')
    type_find(bar, 'foo')
    bar.replace_var.value = +'baz'
    bar.replace
    assert_equal 'baz bar foo', editor.contents
    assert_equal 8, selection_start(editor), 'moves on to the next match'
    bar.replace
    assert_equal 'baz bar baz', editor.contents
    bar.replace
    assert_equal 'baz bar baz', editor.contents, 'nothing left to replace'
    assert_equal 'No match', find_status(bar)
  end

  def test_replace_with_no_match_selected_first_finds_one
    editor, bar = find_fixture('foo bar foo')
    type_find(bar, 'foo')
    editor.text.tag_remove('sel', '1.0', 'end')
    tk(editor.text.path, 'mark', 'set', 'insert', '1.5')
    bar.replace_var.value = +'X'
    bar.replace
    assert_equal 'foo bar foo', editor.contents, 'the first press only selects the next match'
    assert_equal 8, selection_start(editor)
    bar.replace
    assert_equal 'foo bar X', editor.contents
  end

  def test_replace_all
    editor, bar = find_fixture('a1 b22 c333')
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, '\d+')
    bar.replace_var.value = +'#'
    bar.replace_all
    assert_equal 'a# b# c#', editor.contents
    assert_equal 'Replaced 3', find_status(bar)
  end

  def test_replace_all_with_groups_and_multibyte_text
    editor, bar = find_fixture('John Smith é é')
    ivar(bar, :@regexp_var).value = +'1'
    type_find(bar, '(\w+) (\w+)')
    bar.replace_var.value = +'\2 \1'
    bar.replace_all
    assert_equal 'Smith John é é', editor.contents
    ivar(bar, :@regexp_var).value = +'0'
    type_find(bar, 'é')
    bar.replace_var.value = +'e'
    bar.replace_all
    assert_equal 'Smith John e e', editor.contents
  end

  def test_find_key_bindings_menu_and_escape
    editor = GUI::Workspace.new(text: 'x y x').editor
    assert_equal :break, editor.text.fire("#{GUI::MODIFIER}-Key-f")
    bar = editor.find_bar
    assert bar.visible?
    type_find(bar, 'x')
    editor.text.fire("#{GUI::MODIFIER}-Key-g")
    assert_equal 4, selection_start(editor)
    editor.text.fire("#{GUI::MODIFIER}-Key-G")
    assert_equal 0, selection_start(editor)
    bar.find_entry.fire('Escape')
    refute bar.visible?
    assert_nil marks(editor), 'the marks go when the bar closes'
    editor.text.fire("#{GUI::MODIFIER}-Key-g") # Cmd-G with the bar closed opens it
    assert bar.visible?

    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    labels = menubar.entries.last[1][:menu].entries.map { |_, options| options[:label] }
    assert_includes labels, 'Find...'
    assert_includes labels, 'Find Next'
    assert_includes labels, 'Find Previous'
  end

  def test_find_follows_changes_to_the_text
    editor, bar = find_fixture('x')
    type_find(bar, 'x')
    editor.set_contents('x x x')
    assert_equal 3, marks(editor).size, 'new contents are searched'
    editor.text.insert('end', +' x')
    editor.text.fire('KeyRelease')
    assert_equal 4, marks(editor).size, 'typing updates the marks'
  end

  def test_the_transcript_can_be_searched_too
    main = GUI::MainWindow.new
    Transcript.show_cr('searchable line')
    main.editor.show_find
    type_find(main.editor.find_bar, 'searchable')
    assert_equal 1, marks(main.editor).size
  end
end
