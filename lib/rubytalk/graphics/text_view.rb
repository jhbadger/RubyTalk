# frozen_string_literal: true

# A text-editing view, Smalltalk-80's TextView (with TextController): type, select with the mouse or the
# shift-arrow keys, cut, copy and paste, undo, scroll. It is a monospaced editor on the built-in 5x7
# bitmap font, without word wrap (long lines scroll sideways).
#
#   TextView.new(nil, Rectangle.from(0, 0, 200, 100), text: "Hello\nworld") { |text| puts text }
#   TextView.new(model, bounds, aspect: :body)    # reads model.body, writes model.body= as you type,
#                                                 # and reloads when the model says changed(:body)
#   TextView.new(nil, bounds, multiline: false).on_accept = ->(text) { ... }    # a one-line field
#
# The editing itself (insert, move, select, undo ...) is methods of the view, so programs can drive it
# without a mouse; TextController turns the mouse and keys into those calls. Clicking a text view gives it
# the keyboard, which then goes to it wherever the pointer is, until another field is clicked.
class TextView < View
  include Scrollable

  MARGIN_X = 4
  MARGIN_Y = 3
  CELL_WIDTH = Font::CELL_WIDTH
  LINE_HEIGHT = Font::CELL_HEIGHT
  UNDO_LIMIT = 100

  # caret is where the insertion point is, anchor the other end of the selection (the same when nothing is
  # selected); both are character offsets into the text.
  attr_reader :caret, :anchor, :top_line, :left_col, :focused
  # on_change is called with the text after every edit; on_accept with it when Return is pressed in a
  # one-line view. editable false still lets you select and copy. tab_width is how many spaces Tab inserts.
  attr_accessor :on_change, :on_accept, :editable, :multiline, :tab_width, :aspect

  def initialize(model = nil, bounds = Rectangle.from(0, 0, 200, 100), text: nil, aspect: :text,
                 multiline: true, editable: true, &on_change)
    @text = +''
    @caret = 0
    @anchor = 0
    @top_line = 0
    @left_col = 0
    @goal_col = nil
    @undo = []
    @typing = false
    @focused = false
    @tab_width = 2
    @aspect = aspect
    @multiline = multiline
    @editable = editable
    @on_change = on_change
    @on_accept = nil
    super(model, bounds)
    @border_width = 1
    @caret_shape = Cursor.text
    self.cursor = @caret_shape
    self.text = text || model_text || ''
  end

  def default_controller_class
    TextController
  end

  # --- the text --------------------------------------------------------------------

  def text
    @text.dup
  end

  # Replace everything (the caret goes to the start; undo is cleared).
  def text=(string)
    @text = normalize(string)
    @caret = 0
    @anchor = 0
    @top_line = 0
    @left_col = 0
    @goal_col = nil
    @undo.clear
    @typing = false
    invalidate
  end

  # The model changed: show its text again if it is not what we hold.
  def update(aspect = nil, _with = nil)
    if aspect.nil? || aspect == @aspect
      value = model_text
      self.text = value if value && value != @text
    end
    invalidate
  end

  def line_count
    @text.count("\n") + 1
  end

  def lines
    split = @text.split("\n", -1)
    split.empty? ? [''] : split # an empty text is still one (empty) line
  end

  # Offset of the first character of each line.
  def line_starts
    starts = [0]
    @text.each_char.with_index { |char, offset| starts << offset + 1 if char == "\n" }
    starts
  end

  # [line, column] (both from 0) of a character offset (default: the caret).
  def line_and_column(offset = @caret)
    starts = line_starts
    line = (starts.bsearch_index { |start| start > offset } || starts.size) - 1
    [line, offset - starts[line]]
  end

  # --- selection -------------------------------------------------------------------

  # [from, to] of the selected text, or nil if nothing is selected.
  def selection_range
    low, high = [@caret, @anchor].minmax
    low == high ? nil : [low, high]
  end

  def selected_text
    range = selection_range
    range ? @text[range[0]...range[1]] : ''
  end

  # Put the caret at +offset+ and select nothing.
  def place_caret(offset)
    @caret = @anchor = offset.clamp(0, @text.size)
    moved
  end

  # Drag out a selection from the anchor to +offset+.
  def extend_selection(offset)
    @caret = offset.clamp(0, @text.size)
    moved
  end

  def select_all
    @anchor = 0
    @caret = @text.size
    moved
  end

  def select_word_at(offset)
    offset = offset.clamp(0, @text.size)
    low = high = offset
    low -= 1 while low.positive? && word_char?(@text[low - 1])
    high += 1 while high < @text.size && word_char?(@text[high])
    high = [offset + 1, @text.size].min if low == high # not on a word: take the one character
    @anchor = low
    @caret = high
    moved
  end

  def select_line_at(offset)
    line, = line_and_column(offset.clamp(0, @text.size))
    start = line_starts[line]
    @anchor = start
    @caret = start + lines[line].size
    moved
  end

  # Which character offset is under +point+ (view coordinates).
  def index_at(point)
    line = (@top_line + (point.y - MARGIN_Y).div(LINE_HEIGHT)).clamp(0, line_count - 1)
    column = (@left_col + (point.x - MARGIN_X + (CELL_WIDTH / 2)).div(CELL_WIDTH)).clamp(0, lines[line].size)
    line_starts[line] + column
  end

  # --- moving the caret ---------------------------------------------------------------

  DIRECTIONS = %i[left right up down home end word_left word_right text_start text_end page_up page_down].freeze

  # Move the caret; with extend: the selection grows from where it was (shift-arrow).
  def move(direction, extend: false)
    raise ArgumentError, "unknown direction #{direction.inspect}" unless DIRECTIONS.include?(direction)

    keep_goal = %i[up down page_up page_down].include?(direction)
    range = selection_range
    @caret = if range && !extend && direction == :left then range[0]
              elsif range && !extend && direction == :right then range[1]
              else target_for(direction)
              end
    @anchor = @caret unless extend
    @goal_col = nil unless keep_goal
    moved
  end

  # --- editing ---------------------------------------------------------------------------

  # Type +string+ in place of the selection.
  def insert(string)
    text = normalize(string)
    range = selection_range || [@caret, @caret]
    replace_range(range[0], range[1], text, typing: text.size == 1 && text != "\n" && text != ' ')
  end

  def delete_backward
    range = selection_range
    if range then replace_range(range[0], range[1], '')
    elsif @caret.positive? then replace_range(@caret - 1, @caret, '')
    end
  end

  def delete_forward
    range = selection_range
    if range then replace_range(range[0], range[1], '')
    elsif @caret < @text.size then replace_range(@caret, @caret + 1, '')
    end
  end

  def copy
    text = selected_text
    Clipboard.text = text unless text.empty?
  end

  def cut
    copy
    delete_backward unless selection_range.nil?
  end

  def paste
    pasted = Clipboard.text
    insert(pasted) unless pasted.empty?
  end

  # Undo the last edit (typing a run of letters undoes together). Returns false when there is nothing to undo.
  def undo
    snapshot = @undo.pop or return false

    @text, @caret, @anchor = snapshot
    @typing = false
    @goal_col = nil
    edited
    true
  end

  # The one-line field's Return.
  def accept
    @on_accept&.call(text)
  end

  # --- keyboard focus -------------------------------------------------------------------------

  def focused=(flag)
    @focused = flag
    invalidate
  end

  # --- scrolling -------------------------------------------------------------------------------

  def visible_rows
    [(height - (2 * MARGIN_Y)).div(LINE_HEIGHT), 1].max
  end

  def visible_cols
    reserved = scrollbar_visible? ? Scrollable::SCROLLBAR_WIDTH + 1 : 0
    [(width - (2 * MARGIN_X) - reserved).div(CELL_WIDTH), 1].max
  end

  def scroll_lines(count)
    self.scroll_top = @top_line + count
  end

  def scroll_total
    line_count
  end

  def scroll_visible
    visible_rows
  end

  def scroll_top
    @top_line
  end

  def scroll_top=(line)
    @top_line = line.clamp(0, max_scroll_top)
    invalidate
  end

  # Scroll so the caret shows.
  def ensure_caret_visible
    line, column = line_and_column
    @top_line = line if line < @top_line
    @top_line = line - visible_rows + 1 if line >= @top_line + visible_rows
    @top_line = @top_line.clamp(0, max_scroll_top)
    @left_col = column if column < @left_col
    @left_col = column - visible_cols + 1 if column > @left_col + visible_cols - 1
    @left_col = [@left_col, 0].max
  end

  # --- drawing -----------------------------------------------------------------------------------

  def display_view(form)
    starts = line_starts
    all_lines = lines
    cols = visible_cols
    selection = selection_range
    caret_line, caret_col = line_and_column
    visible_rows.times do |row|
      number = @top_line + row
      break if number >= all_lines.size

      y = MARGIN_Y + (row * LINE_HEIGHT)
      line = all_lines[number]
      form.draw_string(line[@left_col, cols].to_s, Point.new(MARGIN_X, y), color: foreground)
      draw_selection(form, selection, starts[number], line, y, cols) if selection
      next unless @focused && number == caret_line && caret_col >= @left_col && caret_col <= @left_col + cols

      form.fill(Rectangle.from(MARGIN_X + ((caret_col - @left_col) * CELL_WIDTH) - 1, y - 1, 1, LINE_HEIGHT), foreground)
    end
    draw_scrollbar(form)
  end

  private

  def model_text
    model.public_send(@aspect).to_s if model && model.respond_to?(@aspect)
  end

  def normalize(string)
    text = string.to_s.gsub("\r\n", "\n").tr("\r", "\n").gsub("\t", ' ' * @tab_width)
    @multiline ? text : text.tr("\n", ' ')
  end

  def word_char?(char)
    char.match?(/\w/)
  end

  # The one place text changes: records undo, moves the caret to the end of what was put in, and tells the
  # model and the on_change block.
  def replace_range(from, to, string, typing: false)
    return unless @editable

    remember(typing)
    @text[from...to] = string
    @caret = @anchor = from + string.size
    @goal_col = nil
    edited
  end

  def remember(typing)
    return if typing && @typing

    @undo << [@text.dup, @caret, @anchor]
    @undo.shift if @undo.size > UNDO_LIMIT
    @typing = typing
  end

  # After a change to the text.
  def edited
    ensure_caret_visible
    if model.respond_to?("#{@aspect}=") && model.public_send(@aspect).to_s != @text
      model.public_send("#{@aspect}=", @text.dup)
    end
    @on_change&.call(text)
    invalidate
  end

  # After the caret or selection moved.
  def moved
    @typing = false
    ensure_caret_visible
    invalidate
  end

  def target_for(direction)
    line, column = line_and_column
    case direction
    when :left then [@caret - 1, 0].max
    when :right then [@caret + 1, @text.size].min
    when :home then line_starts[line]
    when :end then line_starts[line] + lines[line].size
    when :text_start then 0
    when :text_end then @text.size
    when :word_left then word_boundary(-1)
    when :word_right then word_boundary(1)
    when :up then vertical_target(line - 1, column)
    when :down then vertical_target(line + 1, column)
    when :page_up then vertical_target(line - visible_rows, column)
    when :page_down then vertical_target(line + visible_rows, column)
    end
  end

  # The offset on +line+ at the remembered column (so moving through a short line and on keeps your column).
  def vertical_target(line, column)
    return 0 if line.negative?
    return @text.size if line >= line_count

    @goal_col ||= column
    line_starts[line] + [@goal_col, lines[line].size].min
  end

  def word_boundary(direction)
    index = @caret
    if direction.negative?
      index -= 1 while index.positive? && !word_char?(@text[index - 1])
      index -= 1 while index.positive? && word_char?(@text[index - 1])
    else
      index += 1 while index < @text.size && !word_char?(@text[index])
      index += 1 while index < @text.size && word_char?(@text[index])
    end
    index
  end

  # Highlight the selected part of one line: a solid bar with the text redrawn in the background colour.
  def draw_selection(form, selection, line_start, line, y, cols)
    low = [selection[0], line_start].max
    high = [selection[1], line_start + line.size + 1].min # +1: a selected newline shows as one more cell
    return if high <= low

    from = (low - line_start - @left_col).clamp(0, cols)
    to = (high - line_start - @left_col).clamp(0, cols)
    return if to <= from

    form.fill(Rectangle.from(MARGIN_X + (from * CELL_WIDTH), y - 1, (to - from) * CELL_WIDTH, LINE_HEIGHT), foreground)
    form.draw_string(line[@left_col + from, to - from].to_s, Point.new(MARGIN_X + (from * CELL_WIDTH), y), color: background)
  end
end
