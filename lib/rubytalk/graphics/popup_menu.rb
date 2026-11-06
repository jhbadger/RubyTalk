# frozen_string_literal: true

# A menu that pops up over a window, Smalltalk-80's PopUpMenu. Items are labels, or [label, action] pairs
# whose action is called when the item is chosen; the label "-" is a separator line.
#
#   menu = PopUpMenu.new(['Cut', 'Copy', '-', ['Paste', -> { paste }]]) { |index, label| puts label }
#   menu.pop_up(window, Point.new(40, 40))        # at a point of the window (default: the pointer)
#   PopUpMenu.labels("again\nundo\ncopy")          # Smalltalk's way to write the labels
#
# It works like Smalltalk's yellow-button menu: press, drag to an item and release to choose it. If you
# release without moving, the menu stays open as an ordinary click menu: click an item to choose it, click
# anywhere else (or press Escape) to dismiss it; Up, Down and Return also work. A controller offers a menu
# for a mouse button by returning it from #menu_for (see MouseMenuController).
class PopUpMenu < View
  ROW_HEIGHT = 12
  SEPARATOR_HEIGHT = 6
  SEPARATOR = '-'

  # The index of the highlighted item, or nil.
  attr_reader :highlight
  # Called with (index, label) after an item is chosen (and after its own action).
  attr_accessor :on_select

  def self.labels(text, &on_select)
    new(text.to_s.split("\n"), &on_select)
  end

  def initialize(items = [], &on_select)
    @entries = items.map { |item| item.is_a?(Array) ? [item[0].to_s, item[1]] : [item.to_s, nil] }
    @on_select = on_select
    @highlight = nil
    @window = nil
    layout
    super(nil, Rectangle.from(0, 0, @menu_width, @menu_height))
    @border_width = 1
  end

  def labels
    @entries.map(&:first)
  end

  def separator?(index)
    @entries[index] && @entries[index][0] == SEPARATOR
  end

  # Show the menu over +window+ with the pointer at +point+ (window coordinates) inside its first item,
  # kept within the window.
  def pop_up(window, point = nil, manager = ControlManager.instance)
    manager.show_popup(window, self, point || manager.sensor.cursor_point)
  end

  # Called by the window manager: put the menu near +point+, wholly inside +window+.
  def place_in(window, point)
    @window = window
    x = (point.x - 4).clamp(0, [window.width - width, 0].max)
    y = (point.y - 4).clamp(0, [window.height - height, 0].max)
    self.bounds = Rectangle.from(x, y, width, height)
  end

  # The item under +point+ (window coordinates), or nil outside the menu or on a separator.
  def item_at(point)
    local = point - bounds.origin
    return nil unless local_bounds.contains?(local)

    @rows.each_with_index do |(top, row_height), index|
      return index if local.y >= top && local.y < top + row_height && !separator?(index)
    end
    nil
  end

  # Highlight the item under +point+ (none if the pointer is off the menu).
  def track(point)
    index = item_at(point)
    return if index == @highlight

    @highlight = index
    invalidate
  end

  # Up or down the items (+delta+ is 1 or -1), skipping separators and wrapping round.
  def move_highlight(delta)
    selectable = (0...@entries.size).reject { |index| separator?(index) }
    return if selectable.empty?

    position = selectable.index(@highlight)
    target = position ? (position + delta) % selectable.size : (delta.positive? ? 0 : selectable.size - 1)
    @highlight = selectable[target]
    invalidate
  end

  # Choose item +index+: run its action, then the on_select block.
  def choose(index)
    entry = @entries[index]
    return if entry.nil? || separator?(index)

    entry[1]&.call
    @on_select&.call(index, entry[0])
  end

  # The window needs redrawing, not the menu (which is not part of the window's view tree).
  def invalidate
    @window ? @window.invalidate : super
  end

  def display_view(form)
    @entries.each_with_index do |(label, _action), index|
      top, row_height = @rows[index]
      if separator?(index)
        form.fill(Rectangle.from(3, top + (row_height / 2), [width - 6, 0].max, 1), Color.gray)
      elsif index == @highlight
        form.fill(Rectangle.from(1, top, [width - 2, 0].max, row_height), foreground)
        form.draw_string(label, Point.new(8, top + 1), color: background)
      else
        form.draw_string(label, Point.new(8, top + 1), color: foreground)
      end
    end
  end

  private

  def layout
    y = 2
    @rows = @entries.map do |label, _action|
      row_height = label == SEPARATOR ? SEPARATOR_HEIGHT : ROW_HEIGHT
      row = [y, row_height]
      y += row_height
      row
    end
    @menu_height = y + 2
    widest = @entries.map { |label, _action| label == SEPARATOR ? 0 : Font.default.width_of(label) }.max || 0
    @menu_width = [widest + 16, 40].max
  end
end
