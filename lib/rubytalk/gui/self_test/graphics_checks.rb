# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    class SelfTest
      # Checks of the graphics framework running in real Tk windows.
      # Uses the helpers of SelfTest (update, generate, click, assert ...).
      module GraphicsChecks
        # The MVC framework on real Tk: open a window with a button, show it in a Tk canvas, and drive it with
        # genuine mouse events (the %x %y arguments of the bindings), checking the picture reaches Tk.
        def check_graphics_window
          model = GraphicsExamples::Counter.new
          view = StandardSystemView.new('Graphics self-test', model, Point.new(200, 80))
          view.add_subview(ButtonView.new('+', Rectangle.from(10, 10, 60, 30)) { model.increment })
          view.add_subview(StringView.new(model, Rectangle.from(90, 15, 100, 20)) { |counter| "n=#{counter.count}" })
          view.open
          win = GUI.windows.last
          assert(win.is_a?(GraphicsWindow), 'no graphics window opened')
          update
          assert_equal '200', Tk.tk_call('image', 'width', win.image).to_s
          assert_equal '80', Tk.tk_call('image', 'height', win.image).to_s

          generate(win.canvas, '<Motion>', '-x', 20, '-y', 20)
          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 20)
          assert(view.subviews.first.pressed, 'the press at 20,20 did not reach the button (mouse bindings)')
          generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 20)
          assert_equal 1, model.count, 'releasing on the button did not run its action'
          ControlManager.instance.refresh_all
          assert(view.form[95, 20] && view.form.copy(Rectangle.from(90, 15, 100, 20)).to_ascii.join.include?('#'),
                 'the count was not drawn into the window')

          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 20)
          generate(win.canvas, '<B1-Motion>', '-x', 150, '-y', 70)
          assert(!view.subviews.first.pressed, 'dragging off did not un-press the button (drag bindings)')
          generate(win.canvas, '<ButtonRelease-1>', '-x', 150, '-y', 70)
          assert_equal 1, model.count, 'releasing off the button must not run it'
          view.close
          assert_equal '0', Tk.tk_call('winfo', 'exists', win.window.path).to_s, 'closing the view did not close its window'
        ensure
          view&.close if ControlManager.instance.windows.include?(view)
        end

        # A list longer than its window, on real Tk: the wheel, a press on the scroll bar, a click and the
        # arrow keys (which go to the clicked list wherever the pointer is).
        def check_scrolling_list
          view = StandardSystemView.new('Scrolling self-test', nil, Point.new(120, 64))
          list = view.add_subview(ListView.new(Array.new(40) { |i| "row #{i}" }, Rectangle.from(0, 0, 120, 64)))
          view.open
          win = GUI.windows.last
          win.canvas.focus
          update
          assert(list.scrollbar_visible?, 'a 40 row list in a 64 pixel window needs a scroll bar')

          generate(win.canvas, '<MouseWheel>', '-x', 20, '-y', 20, '-delta', -1)
          assert(list.top.positive?, "the wheel did not scroll the list (top is #{list.top})")
          generate(win.canvas, '<MouseWheel>', '-x', 20, '-y', 20, '-delta', 1)
          generate(win.canvas, '<ButtonPress-1>', '-x', 114, '-y', 60)
          generate(win.canvas, '<ButtonRelease-1>', '-x', 114, '-y', 60)
          assert(list.top > 20, "a press low on the scroll bar did not scroll there (top is #{list.top})")

          generate(win.canvas, '<ButtonPress-1>', '-x', 20, '-y', 8)
          generate(win.canvas, '<ButtonRelease-1>', '-x', 20, '-y', 8)
          assert(list.selection, 'clicking a row did not select it')
          before = list.selection
          generate(win.canvas, '<Motion>', '-x', 114, '-y', 5)
          generate(win.canvas, '<KeyPress>', '-keysym', 'Down')
          assert_equal before + 1, list.selection
        ensure
          view&.close if ControlManager.instance.windows.include?(view)
        end

        # Hold the yellow button over a view with a menu, drag to an item and release (real mouse bindings),
        # then show it as a click menu and choose with the keyboard.
        def check_popup_menu
          chosen = []
          view = StandardSystemView.new('Menu self-test', nil, Point.new(160, 120))
          area = view.add_subview(View.new(nil, Rectangle.from(0, 0, 160, 120)))
          controller = MouseMenuController.new(area)
          controller.yellow_button_menu = PopUpMenu.new(%w[Alpha Beta]) { |_index, label| chosen << label }
          area.controller = controller
          view.open
          win = GUI.windows.last
          win.canvas.focus
          update
          yellow = GraphicsWindow::BUTTON_NAMES.key(:yellow)

          generate(win.canvas, "<ButtonPress-#{yellow}>", '-x', 50, '-y', 50)
          assert(view.popup, 'pressing the yellow button did not show the menu (check the button numbering)')
          generate(win.canvas, "<B#{yellow}-Motion>", '-x', 50, '-y', 65)
          generate(win.canvas, "<ButtonRelease-#{yellow}>", '-x', 50, '-y', 65)
          assert_equal ['Beta'], chosen
          assert(view.popup.nil?, 'the menu did not go away after choosing')

          generate(win.canvas, "<ButtonPress-#{yellow}>", '-x', 50, '-y', 50)
          generate(win.canvas, "<ButtonRelease-#{yellow}>", '-x', 50, '-y', 50)
          assert(view.popup, 'releasing without moving should leave a click menu open')
          generate(win.canvas, '<KeyPress>', '-keysym', 'Down')
          generate(win.canvas, '<KeyPress>', '-keysym', 'Return')
          assert_equal %w[Beta Beta], chosen
        ensure
          view&.close if ControlManager.instance.windows.include?(view)
        end
      end

      include GraphicsChecks
    end
  end
end
