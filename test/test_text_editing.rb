# frozen_string_literal: true

# Tests for the text-editing widget (TextView / TextController) and the Notes example. No display needed.
#   ruby test/test_text_editing.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'zlib'
require 'rubytalk'

class TextEditingTest < Minitest::Test
  CELL = TextView::CELL_WIDTH
  ROW = TextView::LINE_HEIGHT

  def setup
    Transcript.clear
    Clipboard.backend = nil
    Clipboard.text = ''
    @manager = ControlManager.new
    @saved_instance = ControlManager.instance_variable_get(:@instance)
    ControlManager.instance_variable_set(:@instance, @manager) # controllers read the shared sensor
  end

  def teardown
    ControlManager.instance_variable_set(:@instance, @saved_instance)
    Clipboard.backend = nil
    Clipboard.text = ''
  end

  def pt(x, y)
    Point.new(x, y)
  end

  def view(text = '', width: 200, height: 60, **options)
    TextView.new(nil, Rectangle.from(0, 0, width, height), text: text, **options)
  end

  # The point in a text view where character +column+ of row +row+ starts.
  def cell(column, row = 0)
    pt(TextView::MARGIN_X + (column * CELL), TextView::MARGIN_Y + (row * ROW) + 2)
  end

  def text_window(text = '', extent: pt(200, 60), **options)
    top = StandardSystemView.new('Text', nil, extent)
    field = top.add_subview(TextView.new(nil, Rectangle.new(pt(0, 0), extent), text: text, **options))
    top.open(@manager)
    [top, field]
  end

  def type(top, string)
    string.each_char do |char|
      char == "\n" ? @manager.key(top, "\r", 'Return') : @manager.key(top, char, char)
    end
  end

  # --- the editing methods --------------------------------------------------------------

  def test_typing_inserts_at_the_caret
    v = view
    v.insert('a')
    v.insert('b')
    assert_equal 'ab', v.text
    assert_equal [2, 2], [v.caret, v.anchor]
    v.place_caret(1)
    v.insert('X')
    assert_equal 'aXb', v.text
    assert_equal 2, v.caret
  end

  def test_typing_replaces_the_selection
    v = view('hello world')
    v.select_word_at(7)
    assert_equal 'world', v.selected_text
    v.insert('there')
    assert_equal 'hello there', v.text
    assert_equal 11, v.caret
    assert_nil v.selection_range
  end

  def test_backspace_and_delete
    v = view('abcd')
    v.place_caret(2)
    v.delete_backward
    assert_equal ['acd', 1], [v.text, v.caret]
    v.delete_forward
    assert_equal 'ad', v.text
    v.place_caret(0)
    v.delete_backward
    assert_equal 'ad', v.text, 'nothing before the start'
    v.place_caret(2)
    v.delete_forward
    assert_equal 'ad', v.text, 'nothing after the end'
    v.select_all
    v.delete_forward
    assert_equal '', v.text, 'with a selection either key deletes it'
    v.insert('x')
    v.select_all
    v.delete_backward
    assert_equal '', v.text
  end

  def test_line_endings_and_tabs_are_normalised
    v = view
    v.insert("a\r\nb\rc\td")
    assert_equal "a\nb\nc  d", v.text
    v.text = "x\ty"
    assert_equal 'x  y', v.text
    v.tab_width = 4
    v.insert("\t")
    assert v.text.start_with?('    '), 'four spaces, at the caret (the start)'
  end

  def test_a_one_line_view_turns_newlines_into_spaces
    v = view('', multiline: false)
    v.insert("a\nb")
    assert_equal 'a b', v.text
    v.text = "one\ntwo"
    assert_equal 'one two', v.text
    assert_equal 1, v.line_count
  end

  def test_movement_by_character_line_and_text
    v = view("abc\ndef\nghi")
    v.place_caret(0)
    v.move(:right)
    assert_equal 1, v.caret
    v.move(:down)
    assert_equal 5, v.caret, 'one down: same column'
    v.move(:down)
    assert_equal 9, v.caret
    v.move(:down)
    assert_equal 11, v.caret, 'down from the last line goes to the end'
    v.move(:up)
    assert_equal 5, v.caret, 'and up remembers the column you were in'
    v.move(:home)
    assert_equal 4, v.caret
    v.move(:end)
    assert_equal 7, v.caret
    v.move(:text_start)
    assert_equal 0, v.caret
    v.move(:left)
    assert_equal 0, v.caret, 'stops at the start'
    v.move(:text_end)
    assert_equal 11, v.caret
    v.move(:right)
    assert_equal 11, v.caret
    v.move(:up)
    v.move(:up)
    v.move(:up)
    assert_equal 0, v.caret, 'up from the first line goes to the start'
  end

  def test_the_column_is_remembered_through_a_short_line
    v = view("long line\nx\nlong line")
    v.place_caret(6)
    v.move(:down)
    assert_equal 11, v.caret, 'the short line: its end'
    v.move(:down)
    assert_equal 12 + 6, v.caret, 'and back to column 6 on the next'
    v.move(:left)
    v.move(:up)
    assert_equal 11, v.caret, 'moving sideways forgets the remembered column'
  end

  def test_movement_by_word
    v = view('foo bar  baz')
    v.move(:word_right)
    assert_equal 3, v.caret
    v.move(:word_right)
    assert_equal 7, v.caret
    v.move(:word_right)
    assert_equal 12, v.caret
    v.move(:word_left)
    assert_equal 9, v.caret
    v.move(:word_left)
    assert_equal 4, v.caret
  end

  def test_extending_the_selection_and_collapsing_it
    v = view('abcdef')
    v.place_caret(2)
    v.move(:right, extend: true)
    v.move(:right, extend: true)
    assert_equal [2, 4], v.selection_range
    assert_equal 'cd', v.selected_text
    v.move(:left, extend: true)
    assert_equal [2, 3], v.selection_range
    v.move(:left)
    assert_equal [2, 2], [v.caret, v.anchor], 'plain left collapses to the start of the selection'
    v.select_all
    v.move(:right)
    assert_equal 6, v.caret
    assert_nil v.selection_range
    assert_raises(ArgumentError) { v.move(:sideways) }
  end

  def test_selecting_words_lines_and_everything
    v = view("one two\nthree")
    v.select_word_at(5)
    assert_equal 'two', v.selected_text
    v.select_word_at(3)
    assert_equal 'one', v.selected_text, 'just after a word selects that word'
    v.select_line_at(10)
    assert_equal 'three', v.selected_text
    v.select_line_at(2)
    assert_equal 'one two', v.selected_text, 'a line without its newline'
    v.select_all
    assert_equal "one two\nthree", v.selected_text
    spaced = view('a  b')
    spaced.select_word_at(2)
    assert_equal ' ', spaced.selected_text, 'between words: the one character'
    empty = view
    empty.select_word_at(0)
    empty.select_line_at(0)
    assert_equal '', empty.selected_text
  end

  def test_points_map_to_character_offsets
    v = view("hello\nworld\n\nlast")
    assert_equal 0, v.index_at(pt(0, 0))
    assert_equal 2, v.index_at(cell(2))
    assert_equal 3, v.index_at(pt(TextView::MARGIN_X + (2 * CELL) + 4, TextView::MARGIN_Y)), 'nearer the next boundary'
    assert_equal 6 + 4, v.index_at(cell(4, 1))
    assert_equal 5, v.index_at(cell(40, 0)), 'past the end of a line: its end'
    assert_equal 12, v.index_at(cell(3, 2)), 'an empty line'
    assert_equal 13 + 4, v.index_at(cell(10, 5)), 'below the text: the last line'
    assert_equal 0, v.index_at(pt(-30, -30))
  end

  def test_line_and_column_helpers
    v = view("ab\ncde\n")
    assert_equal 3, v.line_count
    assert_equal [0, 3, 7], v.line_starts
    assert_equal ['ab', 'cde', ''], v.lines
    assert_equal [1, 2], v.line_and_column(5)
    assert_equal [2, 0], v.line_and_column(7)
    assert_equal [0, 0], v.line_and_column(0)
  end

  # --- undo ------------------------------------------------------------------------------------

  def test_undo_takes_back_runs_of_typing_together
    v = view
    v.insert('a')
    v.insert('b')
    v.insert(' ')
    v.insert('c')
    assert_equal 'ab c', v.text
    assert_equal true, v.undo
    assert_equal 'ab ', v.text
    v.undo
    assert_equal 'ab', v.text
    v.undo
    assert_equal '', v.text
    assert_equal false, v.undo, 'nothing left'
  end

  def test_undo_restores_the_caret_and_deletions
    v = view('hello')
    v.place_caret(5)
    v.delete_backward
    v.delete_backward
    assert_equal 'hel', v.text
    v.undo
    assert_equal ['hell', 4], [v.text, v.caret]
    v.undo
    assert_equal ['hello', 5], [v.text, v.caret]
    v.select_all
    v.insert('X')
    v.undo
    assert_equal 'hello', v.text
  end

  def test_setting_the_text_clears_undo_and_moves_to_the_start
    v = view
    v.insert('abc')
    v.text = 'new'
    assert_equal ['new', 0], [v.text, v.caret]
    assert_equal false, v.undo
  end

  def test_undo_is_bounded
    v = view
    (TextView::UNDO_LIMIT + 20).times { |i| v.insert("#{i} ") }
    steps = 0
    steps += 1 while v.undo
    assert_equal TextView::UNDO_LIMIT, steps
  end

  # --- clipboard ------------------------------------------------------------------------------

  def test_cut_copy_paste
    v = view('hello world')
    v.select_word_at(7)
    v.copy
    assert_equal 'world', Clipboard.text
    assert_equal 'hello world', v.text
    v.select_word_at(1)
    v.cut
    assert_equal ' world', v.text
    assert_equal 'hello', Clipboard.text
    v.place_caret(0)
    v.paste
    assert_equal 'hello world', v.text
    v.select_all
    v.paste
    assert_equal 'hello', v.text, 'paste replaces the selection'
    v.undo
    assert_equal 'hello world', v.text
  end

  def test_copy_with_nothing_selected_and_paste_with_nothing_copied_do_nothing
    v = view('abc')
    Clipboard.text = 'keep'
    v.copy
    assert_equal 'keep', Clipboard.text
    v.cut
    assert_equal 'abc', v.text
    Clipboard.text = ''
    v.paste
    assert_equal 'abc', v.text
  end

  def test_the_clipboard_can_use_another_store
    store = Struct.new(:value) do
      def get = value
      def set(text) = (self.value = text)
    end.new('from outside')
    Clipboard.backend = store
    assert_equal 'from outside', Clipboard.text
    v = view('x')
    v.paste
    assert_equal 'from outsidex', v.text
    v.select_all
    v.copy
    assert_equal 'from outsidex', store.value, 'copying writes to the other store'
    Clipboard.text = nil
    assert_equal '', store.value
  end

  def test_a_read_only_view_selects_and_copies_but_does_not_change
    v = view('read only', editable: false)
    v.insert('x')
    v.select_all
    v.delete_backward
    v.cut
    assert_equal 'read only', v.text
    assert_equal 'read only', Clipboard.text, 'cut copied before refusing to delete'
    assert_equal false, v.undo
  end

  # --- change notification and the model -----------------------------------------------------------

  def test_on_change_hears_every_edit
    heard = []
    v = TextView.new(nil, Rectangle.from(0, 0, 100, 40)) { |text| heard << text }
    v.insert('a')
    v.insert('b')
    v.delete_backward
    v.undo
    assert_equal %w[a ab a ab], heard
  end

  def test_one_line_accept
    got = []
    v = view('hello', multiline: false)
    v.on_accept = ->(text) { got << text }
    v.accept
    assert_equal ['hello'], got
    view('x').accept # no handler: nothing
  end

  class Note < Model
    attr_reader :body

    def initialize
      super
      @body = +'start'
    end

    def body=(text)
      @body = text
      changed(:body)
    end
  end

  def test_the_view_reads_and_writes_a_model_aspect
    note = Note.new
    v = TextView.new(note, Rectangle.from(0, 0, 100, 40), aspect: :body)
    assert_equal 'start', v.text
    assert_equal [v], note.dependents
    v.insert('X')
    assert_equal 'Xstart', note.body, 'typing writes the model'
    assert_equal 1, v.caret, 'and the echo from the model does not reload and move the caret'
    note.body = 'changed elsewhere'
    assert_equal 'changed elsewhere', v.text, 'the model changing reloads the view'
    assert_equal 0, v.caret
    note.changed(:other) # a different aspect: nothing to reload
    assert_equal 'changed elsewhere', v.text
  end

  def test_a_model_without_a_writer_is_fine
    reader_only = Class.new(Model) { define_method(:text) { 'fixed' } }.new
    v = TextView.new(reader_only, Rectangle.from(0, 0, 100, 40))
    assert_equal 'fixed', v.text
    v.insert('!') # no text= to call: no error
    assert_equal '!fixed', v.text
  end

  # --- scrolling --------------------------------------------------------------------------------

  def test_the_view_scrolls_to_keep_the_caret_visible
    v = view(Array.new(30) { |i| "line #{i}" }.join("\n"), height: 60)
    assert_equal 6, v.visible_rows
    assert v.scrollbar_visible?
    v.move(:text_end)
    assert_equal 24, v.top_line, 'the last six lines show'
    v.move(:text_start)
    assert_equal 0, v.top_line
    v.place_caret(v.line_starts[10])
    assert_equal 5, v.top_line, 'caret on line 10: it is the bottom row'
    v.scroll_lines(-100)
    assert_equal 0, v.top_line
    v.scroll_lines(100)
    assert_equal 24, v.top_line
    assert_equal 30, v.scroll_total
  end

  def test_long_lines_scroll_sideways
    v = view('x' * 40, width: 100, height: 18, multiline: false)
    assert_equal 15, v.visible_cols
    refute v.scrollbar_visible?
    v.move(:end)
    assert_equal 26, v.left_col, 'the caret is the last visible column'
    v.move(:home)
    assert_equal 0, v.left_col
  end

  def test_a_short_view_still_shows_one_row
    v = view('a', height: 10)
    assert_equal 1, v.visible_rows
  end

  # --- drawing ----------------------------------------------------------------------------------

  def test_text_selection_and_caret_are_drawn
    v = view('A', width: 60, height: 20)
    plain = v.render
    assert_equal 0, plain[TextView::MARGIN_X, TextView::MARGIN_Y + 2], 'the A has ink where its first column starts'
    assert_equal 0xFFFFFF, plain[TextView::MARGIN_X + 5, TextView::MARGIN_Y], 'and its spacing column is blank'
    assert_equal 0xFFFFFF, plain[TextView::MARGIN_X - 1, TextView::MARGIN_Y], 'no caret while it has no focus'

    v.focused = true
    assert_equal 0, v.render[TextView::MARGIN_X - 1, TextView::MARGIN_Y], 'a caret at the start of the text when focused'

    v.select_all
    assert_equal 0, v.render[TextView::MARGIN_X + 5, TextView::MARGIN_Y], 'the selection is a solid bar'
  end

  def test_a_selected_newline_shows_as_an_extra_cell
    v = view("ab\ncd", width: 80, height: 30)
    v.place_caret(0)
    v.extend_selection(3) # "ab" and its newline
    picture = v.render
    assert_equal 0, picture[TextView::MARGIN_X + (2 * CELL) + 2, TextView::MARGIN_Y], 'the cell after "b" is selected'
    assert_equal 0xFFFFFF, picture[TextView::MARGIN_X + 2, TextView::MARGIN_Y + ROW + 4], 'the next line is not'
  end

  def test_a_text_view_shows_the_text_cursor_shape
    assert_equal 'xterm', view.cursor.tk_name
  end

  # --- the controller: mouse and keys through the window manager ---------------------------------

  def test_clicking_places_the_caret_and_gives_the_view_the_keyboard
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(5).x, cell(5).y, :red)
    @manager.mouse_up(top, cell(5).x, cell(5).y, :red)
    assert_equal 5, field.caret
    assert field.focused
    assert_same field.controller, @manager.focus_controller(top)
    @manager.mouse_move(top, 190, 50) # the pointer wanders: typing still goes to the field
    type(top, 'X')
    assert_equal 'helloX world', field.text
  end

  def test_focus_moves_between_text_views_and_is_drawn
    top = StandardSystemView.new('Two', nil, pt(200, 100))
    one = top.add_subview(TextView.new(nil, Rectangle.from(0, 0, 200, 40)))
    two = top.add_subview(TextView.new(nil, Rectangle.from(0, 50, 200, 40)))
    top.open(@manager)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    assert [one.focused, two.focused] == [true, false]
    @manager.mouse_down(top, 10, 60, :red)
    @manager.mouse_up(top, 10, 60, :red)
    assert [one.focused, two.focused] == [false, true]
    type(top, 'z')
    assert_equal ['', 'z'], [one.text, two.text]
  end

  def test_typing_and_editing_keys
    top, field = text_window
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    type(top, "ab\ncd")
    assert_equal "ab\ncd", field.text
    @manager.key(top, "\b", 'BackSpace')
    assert_equal "ab\nc", field.text
    @manager.key(top, '', 'Left')
    @manager.key(top, '', 'Delete')
    assert_equal "ab\n", field.text
    @manager.key(top, "\t", 'Tab')
    assert_equal "ab\n  ", field.text, 'Tab types two spaces'
    @manager.key(top, '', 'Shift_L') # a lone modifier key: ignored
    @manager.key(top, "\e", 'Escape')
    @manager.key(top, "\x01", 'a') # a control character: ignored
    @manager.key(top, "\u007f", 'Delete') # at the end: nothing to delete
    assert_equal "ab\n  ", field.text
  end

  def test_arrow_keys_with_shift_and_control
    top, field = text_window('foo bar baz')
    @manager.mouse_down(top, cell(0).x, cell(0).y, :red)
    @manager.mouse_up(top, cell(0).x, cell(0).y, :red)
    @manager.key(top, '', 'Right')
    @manager.key(top, '', 'Right', InputSensor::SHIFT)
    @manager.key(top, '', 'Right', InputSensor::SHIFT)
    assert_equal [1, 3], field.selection_range
    @manager.key(top, '', 'Right', InputSensor::CONTROL)
    assert_equal 7, field.caret, 'control moves by words (and drops the selection)'
    assert_nil field.selection_range
    @manager.key(top, '', 'Left', InputSensor::CONTROL | InputSensor::SHIFT)
    assert_equal [4, 7], field.selection_range, 'control and shift select back a word'
    @manager.key(top, '', 'Home')
    assert_equal 0, field.caret
    @manager.key(top, '', 'End')
    assert_equal 11, field.caret
  end

  def test_return_in_a_one_line_field_accepts
    got = []
    top, field = text_window('abc', multiline: false)
    field.on_accept = ->(text) { got << text }
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    @manager.key(top, "\r", 'Return')
    @manager.key(top, "\t", 'Tab')
    assert_equal ['abc'], got
    assert_equal 'abc', field.text, 'neither Return nor Tab typed anything'
  end

  def test_dragging_selects
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(2).x, cell(2).y, :red)
    @manager.mouse_move(top, cell(8).x, cell(8).y)
    @manager.mouse_move(top, 500, 500) # dragged right out of the field: selects to the end
    @manager.mouse_up(top, 500, 500, :red)
    assert_equal [2, 11], field.selection_range
    @manager.mouse_move(top, cell(1).x, cell(1).y) # not dragging any more
    assert_equal [2, 11], field.selection_range
  end

  def test_double_and_triple_clicks_and_shift_click
    now = 10.0
    @manager.clock = -> { now }
    top, field = text_window("one two three\nsecond line")
    click = lambda do |column, row = 0, state = 0|
      @manager.mouse_down(top, cell(column, row).x, cell(column, row).y, :red, state)
      @manager.mouse_up(top, cell(column, row).x, cell(column, row).y, :red)
      now += 0.1
    end
    click.call(5)
    assert_equal 5, field.caret
    click.call(5)
    assert_equal 'two', field.selected_text, 'double click: the word'
    click.call(5)
    assert_equal 'one two three', field.selected_text, 'triple click: the line'
    now += 5
    click.call(2)
    assert_nil field.selection_range
    click.call(9, 0, InputSensor::SHIFT)
    assert_equal [2, 9], field.selection_range, 'shift-click extends from the caret'
  end

  def test_the_wheel_and_scroll_bar_scroll_the_text
    top, field = text_window(Array.new(30) { |i| "line #{i}" }.join("\n"), extent: pt(200, 60))
    @manager.mouse_wheel(top, 20, 20, 3)
    assert_equal 3, field.top_line
    @manager.mouse_wheel(top, 20, 20, -1)
    assert_equal 2, field.top_line
    @manager.mouse_down(top, 195, 55, :red) # low on the scroll bar
    assert_operator field.top_line, :>, 15
    @manager.mouse_move(top, 195, 3)
    assert_equal 0, field.top_line
    @manager.mouse_up(top, 195, 3, :red)
    assert_nil field.selection_range, 'the scroll bar did not move the caret'
  end

  def test_command_keys_select_copy_cut_paste_and_undo
    top, field = text_window('hello world')
    @manager.mouse_down(top, cell(0).x, cell(0).y, :red)
    @manager.mouse_up(top, cell(0).x, cell(0).y, :red)
    assert_equal true, @manager.command_key(top, 'a')
    assert_equal 'hello world', field.selected_text
    assert_equal true, @manager.command_key(top, 'c')
    assert_equal 'hello world', Clipboard.text
    assert_equal true, @manager.command_key(top, 'X') # capital: the same key
    assert_equal '', field.text
    assert_equal true, @manager.command_key(top, 'v')
    assert_equal 'hello world', field.text
    assert_equal true, @manager.command_key(top, 'z')
    assert_equal '', field.text
    assert_equal false, @manager.command_key(top, 'q'), 'other combinations are left alone'
  end

  def test_the_default_yellow_menu_edits
    top, field = text_window('hello world', extent: pt(200, 120))
    @manager.mouse_down(top, 60, 40, :yellow)
    refute_nil top.popup
    assert_equal %w[Undo - Cut Copy Paste - Select\ all], top.popup.labels
    @manager.mouse_up(top, 60, 40, :yellow) # a click menu
    4.times { @manager.key(top, '', 'Down') } # Undo, Cut, Copy, Paste, Select all
    @manager.key(top, '', 'Return')
    assert_equal 'hello world', field.selected_text
    assert_nil top.popup
  end

  def test_a_custom_menu_replaces_the_default
    top, field = text_window('x', extent: pt(200, 120))
    field.controller.yellow_button_menu = PopUpMenu.new(%w[Only])
    @manager.mouse_down(top, 60, 40, :yellow)
    assert_equal ['Only'], top.popup.labels
    assert_nil field.controller.menu_for(:red)
    assert_nil field.controller.menu_for(:blue)
  end

  def test_keys_reach_the_focused_field_even_over_other_widgets
    top = StandardSystemView.new('Mixed', nil, pt(200, 100))
    field = top.add_subview(TextView.new(nil, Rectangle.from(0, 0, 200, 40)))
    pressed = []
    top.add_subview(ButtonView.new('b', Rectangle.from(0, 60, 40, 30)) { pressed << :b })
    top.open(@manager)
    @manager.mouse_down(top, 10, 10, :red)
    @manager.mouse_up(top, 10, 10, :red)
    @manager.mouse_move(top, 10, 70) # over the button
    type(top, 'ok')
    assert_equal 'ok', field.text
    assert_empty pressed
  end

  def test_closing_the_window_with_a_focused_field_is_clean
    top, = text_window('x')
    @manager.mouse_down(top, 10, 10, :red)
    top.close(@manager)
    assert_nil @manager.focus_controller(top)
  end

  # --- the Notes example ------------------------------------------------------------------------

  def test_notes_example_ties_a_list_a_menu_and_an_editor_together
    window = GraphicsExamples::Notes.open
    model = window.subviews.first.model
    list = window.subviews[0]
    field = window.subviews[2]
    assert_equal ['Welcome to Notes'], model.titles
    assert_equal 0, list.selection
    assert_match(/Click a note/, field.text)

    @manager.mouse_down(window, 20, 260, :red) # the New note button
    @manager.mouse_up(window, 20, 260, :red)
    assert_equal 2, model.notes.size
    assert_equal 1, list.selection, 'the new note is selected'
    assert_equal '', field.text
    assert_equal ['Welcome to Notes', '(empty)'], list.items

    @manager.mouse_down(window, 200, 20, :red) # into the editor
    @manager.mouse_up(window, 200, 20, :red)
    type(window, 'Shopping')
    assert_equal 'Shopping', model.notes[1]
    assert_equal ['Welcome to Notes', 'Shopping'], list.items, 'the list follows what is typed'

    @manager.mouse_down(window, 20, 8, :red) # back to the first note
    @manager.mouse_up(window, 20, 8, :red)
    assert_equal 0, model.selected
    assert_match(/Welcome/, field.text)
    assert_equal 0, field.caret

    @manager.mouse_down(window, 20, 100, :yellow) # the list menu: New note, Duplicate, -, Delete
    @manager.mouse_up(window, 20, 100, :yellow)
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Return') # Duplicate
    assert_equal 3, model.notes.size
    assert_equal model.notes[0], model.notes[1]

    @manager.mouse_down(window, 20, 100, :yellow)
    @manager.mouse_up(window, 20, 100, :yellow)
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Down')
    @manager.key(window, '', 'Return') # Delete
    assert_equal 2, model.notes.size
    assert_equal ['Welcome to Notes', 'Shopping'], model.titles
  end

  def test_notes_always_keep_one_note
    model = GraphicsExamples::Notes.new
    model.delete_selected
    assert_equal 1, model.notes.size
    model.select(5) # no such note
    assert_equal 0, model.selected
  end
end
