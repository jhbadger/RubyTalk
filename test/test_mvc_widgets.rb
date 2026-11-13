# frozen_string_literal: true

# Buttons, scrolling lists and pop-up menus.
#   ruby test/test_mvc_widgets.rb

require_relative 'support/mvc_case'

class MvcWidgetsTest < MvcCase
  def button_window(clicks)
    top = window(pt(100, 60))
    button = top.add_subview(ButtonView.new('Go', Rectangle.from(10, 10, 60, 30)) { clicks << :clicked })
    top.open(@manager)
    [top, button]
  end

  def numbers(count)
    Array.new(count) { |i| "item #{i}" }
  end

  def scrolling_window(count = 30, chosen = [])
    top = window(pt(100, 64))
    list = ListView.new(numbers(count), Rectangle.from(0, 0, 100, 64)) { |index, item| chosen << [index, item] }
    top.add_subview(list)
    top.open(@manager)
    [top, list]
  end

  # A window whose one big view has a yellow-button menu; +chosen+ collects what was picked.
  def menu_window(chosen = [], extent: pt(200, 150))
    top = window(extent)
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, extent.x, extent.y)))
    log = []
    controller = Class.new(MouseMenuController) do
      define_method(:mouse_down) { |point, button| log << [:down, point, button] }
      define_method(:mouse_up) { |point, button| log << [:up, point, button] }
      define_method(:mouse_move) { |point| log << [:move, point] }
    end.new(area)
    area.controller = controller
    controller.yellow_button_menu = PopUpMenu.new(['Alpha', '-', ['Beta', -> { chosen << :beta_action }], 'Gamma']) do |index, label|
      chosen << [index, label]
    end
    top.open(@manager)
    [top, controller, log]
  end

  # --- Widgets ----------------------------------------------------------------------------

  def test_string_views_show_fixed_or_computed_text
    model = Struct.new(:n).new(3)
    computed = StringView.new(model, Rectangle.from(0, 0, 80, 12)) { |m| "n=#{m.n}" }
    assert_equal 'n=3', computed.string
    model.n = 4
    assert_equal 'n=4', computed.string
    fixed = StringView.new(nil, Rectangle.from(0, 0, 80, 12), text: 'Hello', scale: 1)
    assert_equal 'Hello', fixed.string
    assert_operator fixed.render.to_ascii.join.count('#'), :>, 10
    assert_equal 0, StringView.new(nil, Rectangle.from(0, 0, 80, 12)).render.to_ascii.join.count('#')
  end


  def test_a_button_acts_when_released_inside
    clicks = []
    top, button = button_window(clicks)
    @manager.mouse_down(top, 20, 20, :red)
    assert button.pressed
    assert_empty clicks, 'not yet: only on release'
    @manager.mouse_up(top, 22, 22, :red)
    refute button.pressed
    assert_equal [:clicked], clicks
  end

  def test_a_button_released_outside_does_nothing_and_re_arms_when_dragged_back
    clicks = []
    top, button = button_window(clicks)
    @manager.mouse_down(top, 20, 20, :red)
    @manager.mouse_move(top, 90, 55)
    refute button.pressed, 'dragged off: it pops up'
    @manager.mouse_move(top, 25, 25)
    assert button.pressed, 'dragged back on: pressed again'
    @manager.mouse_move(top, 95, 55)
    @manager.mouse_up(top, 95, 55, :red)
    assert_empty clicks
    refute button.pressed
    @manager.mouse_down(top, 20, 20, :yellow) # other buttons do not press it
    refute button.pressed
    @manager.mouse_up(top, 20, 20, :yellow)
    assert_empty clicks
  end

  def test_a_pressed_button_looks_inverted
    top, button = button_window([])
    normal = top.form.copy(Rectangle.from(10, 10, 60, 30))
    @manager.mouse_down(top, 20, 20, :red)
    assert button.pressed
    pressed = top.form.copy(Rectangle.from(10, 10, 60, 30))
    refute_equal normal, pressed
    assert_equal 0xFFFFFF, normal[3, 3], 'the inside of a button is the background'
    assert_equal 0x000000, pressed[3, 3], 'and it inverts while pressed'
    assert_equal 0x000000, pressed[0, 0], 'the border is drawn on top and stays'
  end

  def test_list_views_select_rows_and_tell_their_block
    chosen = []
    list = ListView.new(%w[red green blue], Rectangle.from(0, 0, 80, 60)) { |index, item| chosen << [index, item] }
    top = window(pt(100, 80))
    top.add_subview(list, Rectangle.from(10, 10, 80, 60))
    top.open(@manager)
    @manager.mouse_down(top, 20, 10 + 2 + 12 + 3, :red) # second row
    assert_equal [[1, 'green']], chosen
    assert_equal 1, list.selection
    assert_equal 'green', list.selected_item
    @manager.mouse_down(top, 20, 10 + 50, :red) # below the last row
    assert_equal [[1, 'green']], chosen, 'a click on empty space selects nothing new'
    @manager.mouse_down(top, 20, 12, :yellow)
    assert_equal 1, list.selection, 'only the red button selects'
    list.items = %w[a b]
    assert_nil list.selection
    assert_equal %w[a b], list.items
    list.selection = 5
    assert_nil list.selection, 'out of range selects nothing'
    list.selection = 0
    assert_equal 'a', list.selected_item
  end

  def test_the_selected_row_is_drawn_inverted
    list = ListView.new(%w[one two], Rectangle.from(0, 0, 60, 40))
    plain = list.render.to_ascii.join.count('#')
    list.selection = 0
    selected = list.render
    refute_equal plain, selected.to_ascii.join.count('#')
    assert_equal 0, selected[3, 3], 'the selection bar is solid foreground'
  end

  # --- Scrolling lists ----------------------------------------------------------------------



  def test_a_list_shows_only_the_rows_that_fit_and_scrolls
    top, list = scrolling_window
    assert_equal 5, list.visible_rows, '64 pixels high: (64 - 4) / 12'
    assert_equal 0, list.top
    first_page = top.form.to_ascii.join
    list.scroll_by(3)
    assert_equal 3, list.top
    @manager.refresh(top)
    refute_equal first_page, top.form.to_ascii.join, 'the picture scrolled'
    list.scroll_by(1000)
    assert_equal 25, list.top, 'stops when the last row is at the bottom'
    list.scroll_by(-1000)
    assert_equal 0, list.top
    assert_equal 30, list.scroll_total
  end

  def test_the_scroll_bar_appears_only_when_needed
    _top, long = scrolling_window(30)
    _top2, short = scrolling_window(3)
    assert long.scrollbar_visible?
    refute short.scrollbar_visible?
    bar = long.scrollbar_rect
    assert_operator long.render[bar.left + 2, bar.top + 2], :!=, 0xFFFFFF, 'something is drawn there'
    assert_equal 0xFFFFFF, short.render[short.width - 4, 4], 'but not for a short list'
  end

  def test_the_thumb_reflects_the_scroll_position
    _top, list = scrolling_window(30)
    start = list.thumb_rect
    assert_equal list.scrollbar_rect.top, start.top, 'at the top'
    assert_in_delta list.scrollbar_rect.height * 5 / 30.0, start.height, 2
    list.scroll_by(1000)
    finish = list.thumb_rect
    assert_equal list.scrollbar_rect.bottom, finish.bottom, 'at the bottom'
    list.scroll_by(-1000)
    list.scroll_to_point(pt(95, 1000))
    assert_equal 25, list.top, 'dragging the thumb to the bottom'
    list.scroll_to_point(pt(95, -50))
    assert_equal 0, list.top
    list.scroll_to_point(pt(95, list.scrollbar_rect.center.y))
    assert_in_delta 12, list.top, 2, 'the middle'
  end

  def test_clicking_and_dragging_the_scroll_bar
    top, list = scrolling_window(30)
    chosen = []
    list.on_select = ->(index, _item) { chosen << index }
    @manager.mouse_down(top, 95, 60, :red)
    assert_operator list.top, :>, 15, 'a press low on the bar scrolls there'
    assert_empty chosen, 'and does not select a row'
    @manager.mouse_move(top, 95, 5)
    assert_equal 0, list.top, 'dragging follows the pointer'
    @manager.mouse_move(top, 20, 30) # off the bar, still dragging: still scrolls (to the middle)
    middle = list.top
    assert_in_delta 12, middle, 2
    @manager.mouse_up(top, 20, 30, :red)
    @manager.mouse_move(top, 95, 60) # no longer dragging: the list stays where it was
    assert_equal middle, list.top
  end

  def test_the_wheel_scrolls_the_list_under_the_pointer
    top, list = scrolling_window
    @manager.mouse_wheel(top, 20, 20, 3)
    assert_equal 3, list.top
    @manager.mouse_wheel(top, 20, 20, -1)
    assert_equal 2, list.top
    @manager.mouse_wheel(top, 20, 20, -50)
    assert_equal 0, list.top
    other = window(pt(50, 50))
    other.open(@manager)
    @manager.mouse_wheel(other, 5, 5, 3) # a view with no use for it: nothing happens, no error
  end

  def test_clicking_a_row_of_a_scrolled_list_selects_that_row
    chosen = []
    top, list = scrolling_window(30, chosen)
    list.scroll_by(10)
    @manager.mouse_down(top, 20, 2 + 6, :red)
    @manager.mouse_up(top, 20, 8, :red)
    assert_equal [[10, 'item 10']], chosen
    @manager.mouse_down(top, 20, 2 + (12 * 2) + 3, :red)
    assert_equal [10, 12], chosen.map(&:first)
    assert_equal 12, list.selection
    @manager.mouse_down(top, 20, 1, :red) # above the first row: nothing
    assert_equal 2, chosen.size
  end

  def test_keys_move_the_selection_and_scroll_to_keep_it_visible
    chosen = []
    top, list = scrolling_window(30, chosen)
    @manager.mouse_down(top, 20, 8, :red) # clicking the list gives it the keyboard
    @manager.mouse_up(top, 20, 8, :red)
    assert_equal 0, list.selection
    @manager.mouse_move(top, 95, 5) # the pointer wanders off the rows: keys still go to the list
    @manager.key(top, '', 'Down')
    @manager.key(top, '', 'Down')
    assert_equal 2, list.selection
    5.times { @manager.key(top, '', 'Down') }
    assert_equal 7, list.selection
    assert_equal 3, list.top, 'scrolled so row 7 is the last one showing (rows 3 to 7)'
    @manager.key(top, '', 'Up')
    assert_equal 6, list.selection
    @manager.key(top, '', 'Next') # page down: 4 rows
    assert_equal 10, list.selection
    @manager.key(top, '', 'Prior')
    assert_equal 6, list.selection
    @manager.key(top, '', 'End')
    assert_equal 29, list.selection
    assert_equal 25, list.top
    @manager.key(top, '', 'Home')
    assert_equal 0, list.selection
    assert_equal 0, list.top
    @manager.key(top, '', 'Up')
    assert_equal 0, list.selection, 'stops at the first row'
    assert_equal chosen.last, [0, 'item 0']
    assert_equal list, @manager.focus_controller(top).view
  end

  def test_the_first_down_arrow_selects_the_first_row
    top, list = scrolling_window
    @manager.mouse_down(top, 95, 5, :red) # on the scroll bar: focus, but no row selected
    @manager.mouse_up(top, 95, 5, :red)
    assert_nil list.selection
    @manager.key(top, '', 'Down')
    assert_equal 0, list.selection
  end

  def test_setting_the_selection_in_code_scrolls_to_it
    _top, list = scrolling_window
    list.selection = 20
    assert_equal 16, list.top
    list.selection = 2
    assert_equal 2, list.top
    list.items = numbers(3)
    assert_nil list.selection
    assert_equal 0, list.top, 'a shorter list cannot stay scrolled'
    assert_empty ListView.new([], Rectangle.from(0, 0, 50, 50)).tap(&:select_first).items
  end

  # --- Pop-up menus ---------------------------------------------------------------------------


  def test_popup_menu_layout_and_labels
    menu = PopUpMenu.new(['Alpha', '-', 'Beta'])
    assert_equal %w[Alpha - Beta], menu.labels
    assert menu.separator?(1)
    refute menu.separator?(0)
    assert_equal 2 + 12 + 6 + 12 + 2, menu.height, 'two rows and a short separator, with margins'
    assert_operator menu.width, :>=, Font.default.width_of('Alpha') + 16
    assert_equal 40, PopUpMenu.new(['a']).width, 'a minimum width'
    assert_equal %w[again undo copy], PopUpMenu.labels("again\nundo\ncopy").labels
    assert_empty PopUpMenu.new.labels
  end

  def test_popup_menu_items_by_position_and_highlighting
    top = window(pt(200, 150))
    menu = PopUpMenu.new(['Alpha', '-', 'Beta'])
    menu.place_in(top, pt(50, 40))
    assert_equal pt(46, 36), menu.bounds.origin, 'the pointer lands inside the first item'
    assert_equal 0, menu.item_at(pt(50, 40))
    assert_nil menu.item_at(pt(50, 36 + 2 + 12 + 2)), 'a separator is not an item'
    assert_equal 2, menu.item_at(pt(50, 36 + 2 + 12 + 6 + 3))
    assert_nil menu.item_at(pt(5, 5)), 'outside'
    assert_nil menu.highlight
    menu.track(pt(50, 40))
    assert_equal 0, menu.highlight
    menu.track(pt(5, 5))
    assert_nil menu.highlight
  end

  def test_popup_menus_stay_inside_the_window
    top = window(pt(100, 60))
    menu = PopUpMenu.new(%w[one two three four])
    menu.place_in(top, pt(95, 55))
    assert_operator menu.bounds.right, :<=, 100
    assert_operator menu.bounds.bottom, :<=, 60
    menu.place_in(top, pt(-20, -20))
    assert_equal pt(0, 0), menu.bounds.origin
    tiny = window(pt(20, 20))
    menu.place_in(tiny, pt(5, 5)) # bigger than the window: top-left corner, no error
    assert_equal pt(0, 0), menu.bounds.origin
  end

  def test_highlight_moves_over_items_skipping_separators_and_wraps
    menu = PopUpMenu.new(['a', '-', 'b', 'c'])
    menu.move_highlight(1)
    assert_equal 0, menu.highlight
    menu.move_highlight(1)
    assert_equal 2, menu.highlight, 'the separator is skipped'
    menu.move_highlight(1)
    menu.move_highlight(1)
    assert_equal 0, menu.highlight, 'wraps round'
    menu.move_highlight(-1)
    assert_equal 3, menu.highlight
    fresh = PopUpMenu.new(%w[x y z])
    fresh.move_highlight(-1)
    assert_equal 2, fresh.highlight, 'up from nothing starts at the last'
    PopUpMenu.new.move_highlight(1) # an empty menu: no error
  end

  def test_choosing_runs_the_items_action_then_the_block
    log = []
    menu = PopUpMenu.new([['One', -> { log << :one }], 'Two', '-']) { |index, label| log << [index, label] }
    menu.choose(0)
    menu.choose(1)
    menu.choose(2) # a separator
    menu.choose(9) # no such item
    assert_equal [:one, [0, 'One'], [1, 'Two']], log
    menu.on_select = ->(_i, _l) { log << :replaced }
    menu.choose(1)
    assert_equal :replaced, log.last
  end

  def test_press_drag_and_release_chooses_the_item_under_the_pointer
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    assert_kind_of PopUpMenu, top.popup, 'the menu is showing'
    assert_empty log, 'the press went to the menu, not the controller'
    assert_equal 0, top.popup.highlight, 'the first item is under the pointer'
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4) # down onto Beta
    assert_equal 2, top.popup.highlight
    @manager.mouse_up(top, 100, 60 + 2 + 12 + 6 + 4, :yellow)
    assert_nil top.popup, 'the menu goes away'
    assert_equal [:beta_action, [2, 'Beta']], chosen
    assert_empty log, 'the controller saw none of it'
    refute @manager.sensor.any_button_pressed?
  end

  def test_release_off_the_menu_after_dragging_cancels
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_move(top, 190, 140)
    @manager.mouse_up(top, 190, 140, :yellow)
    assert_nil top.popup
    assert_empty chosen
    assert_empty log
  end

  def test_release_without_moving_leaves_a_click_menu_open
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    refute_nil top.popup, 'a click menu: it stays'
    assert_empty chosen
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4)
    assert_equal 2, top.popup.highlight
    @manager.mouse_down(top, 100, 60 + 2 + 12 + 6 + 4, :red) # any button chooses
    assert_nil top.popup
    assert_equal [:beta_action, [2, 'Beta']], chosen
    @manager.mouse_up(top, 100, 60 + 2 + 12 + 6 + 4, :red)
    assert_empty log, 'the release that finished the choice does not leak to the controller'
    @manager.mouse_move(top, 10, 10)
    assert_equal [[:move, pt(10, 10)]], log, 'afterwards the controller works as normal'
  end

  def test_clicking_outside_a_click_menu_dismisses_it
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_down(top, 10, 140, :red)
    @manager.mouse_up(top, 10, 140, :red)
    assert_nil top.popup
    assert_empty chosen
    assert_empty log, 'the dismissing click is not delivered'
  end

  def test_keys_drive_an_open_menu_and_do_not_reach_controllers
    chosen = []
    top, controller, = menu_window(chosen)
    keys = []
    controller.define_singleton_method(:key_pressed) { |char, keysym| keys << [char, keysym] }
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.key(top, '', 'Down')
    assert_equal 2, top.popup.highlight, 'from Alpha down, skipping the separator'
    @manager.key(top, 'x', 'x')
    @manager.key(top, '', 'Return')
    assert_nil top.popup
    assert_equal [:beta_action, [2, 'Beta']], chosen
    assert_empty keys

    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.key(top, '', 'Escape')
    assert_nil top.popup, 'Escape dismisses'
    assert_equal 2, chosen.size, 'Escape chose nothing more (the first choice recorded its action and its label)'
    @manager.key(top, 'q', 'q')
    assert_equal [['q', 'q']], keys, 'with the menu gone keys flow again'
  end

  def test_return_with_nothing_highlighted_dismisses
    top, = menu_window
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_move(top, 5, 5) # off the menu: nothing highlighted
    @manager.key(top, '', 'Return')
    assert_nil top.popup
  end

  def test_other_buttons_use_the_controller_normally
    chosen = []
    top, _controller, log = menu_window(chosen)
    @manager.mouse_down(top, 100, 60, :red)
    @manager.mouse_up(top, 100, 60, :red)
    assert_nil top.popup, 'only the yellow button has a menu'
    assert_equal [[:down, pt(100, 60), :red], [:up, pt(100, 60), :red]], log
  end

  def test_the_wheel_and_command_keys_are_ignored_while_a_menu_is_open
    top, controller, = menu_window
    wheeled = []
    controller.define_singleton_method(:mouse_wheel) { |_point, lines| wheeled << lines }
    controller.define_singleton_method(:command_key) { |_keysym| true }
    @manager.mouse_down(top, 100, 60, :yellow)
    @manager.mouse_up(top, 100, 60, :yellow)
    @manager.mouse_wheel(top, 100, 60, 3)
    assert_empty wheeled
    assert_equal false, @manager.command_key(top, 'c')
  end

  def test_the_menu_is_drawn_over_the_window_and_removed_when_dismissed
    top, = menu_window
    before = top.form.to_ascii.join
    @manager.mouse_down(top, 100, 60, :yellow)
    during = top.form
    refute_equal before, during.to_ascii.join, 'the menu is in the window picture'
    menu = top.popup
    assert_equal 0x000000, during[menu.bounds.left, menu.bounds.top], 'with a border'
    assert_equal 0x000000, during[menu.bounds.left + 3, menu.bounds.top + 4], 'the highlighted first row is solid'
    @manager.mouse_move(top, 100, 60 + 2 + 12 + 6 + 4)
    refute_equal during, top.form, 'the highlight moved'
    @manager.key(top, '', 'Escape')
    assert_equal before, top.form.to_ascii.join, 'and it is gone again'
  end

  def test_a_menu_action_that_fails_is_reported_and_the_menu_still_closes
    top = window(pt(100, 100))
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, 100, 100)))
    controller = MouseMenuController.new(area)
    controller.yellow_button_menu = PopUpMenu.new([['Boom', -> { raise 'menu trouble' }]])
    area.controller = controller
    top.open(@manager)
    @manager.mouse_down(top, 50, 50, :yellow)
    @manager.mouse_up(top, 50, 70, :yellow) # moved: choose what is under the pointer
    @manager.mouse_up(top, 50, 50, :yellow) # stray extra release: harmless
    assert_nil top.popup
    @manager.mouse_move(top, 10, 10)
    @manager.mouse_down(top, 50, 50, :yellow)
    @manager.mouse_move(top, 50, 54)
    @manager.mouse_up(top, 50, 54, :yellow)
    assert_match(/Error in the window 'Test'.*menu trouble/m, Transcript.buffer)
    assert_nil top.popup
  end

  def test_choosing_can_open_another_menu
    top = window(pt(200, 100))
    second = PopUpMenu.new(%w[inner])
    first = PopUpMenu.new([['outer', -> { @manager.show_popup(top, second, pt(100, 50)) }]])
    area = top.add_subview(View.new(nil, Rectangle.from(0, 0, 200, 100)))
    controller = MouseMenuController.new(area)
    controller.blue_button_menu = first
    area.controller = controller
    top.open(@manager)
    @manager.mouse_down(top, 30, 30, :blue)
    @manager.mouse_up(top, 30, 36, :blue)
    assert_same second, top.popup, 'the choice showed the next menu'
  end

  def test_menus_can_be_shown_from_code
    chosen = []
    top = window(pt(200, 120))
    top.open(@manager)
    menu = PopUpMenu.new(%w[first second]) { |i, label| chosen << [i, label] }
    ControlManager.stub(:instance, @manager) { menu.pop_up(top, pt(20, 20)) }
    assert_same menu, top.popup
    assert_equal 0, top.popup.highlight, 'the pointer is over the first item'
    @manager.key(top, '', 'Down')
    @manager.key(top, '', 'Return')
    assert_equal [[1, 'second']], chosen
    @manager.sensor.move_to(pt(40, 40))
    ControlManager.stub(:instance, @manager) { menu.pop_up(top) } # at the pointer
    assert_equal pt(36, 36), top.popup.bounds.origin
  end

  def test_closing_a_window_drops_its_menu_state
    top, = menu_window
    @manager.mouse_down(top, 100, 60, :yellow)
    top.close(@manager)
    @manager.mouse_up(top, 100, 60, :yellow) # no window, no menu: nothing to do
    @manager.key(top, '', 'Return')
  end

  def test_lists_can_have_menus_too
    chosen = []
    top = window(pt(200, 100))
    list = top.add_subview(ListView.new(%w[a b c], Rectangle.from(0, 0, 100, 100)))
    list.controller.yellow_button_menu = PopUpMenu.new(%w[Open Delete]) { |_i, label| chosen << label }
    top.open(@manager)
    @manager.mouse_down(top, 20, 20, :yellow)
    @manager.mouse_move(top, 20, 20 + 2 + 12 + 3)
    @manager.mouse_up(top, 20, 20 + 2 + 12 + 3, :yellow)
    assert_equal ['Delete'], chosen
    assert_nil list.selection, 'the menu press did not select a row'
  end
end
