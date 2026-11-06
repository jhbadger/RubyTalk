# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # A Tk window showing a StandardSystemView. The view draws itself into a Form (see View#render); this
    # shows that picture in a canvas and turns the canvas's mouse and key events into calls on the
    # ControlManager, which hands them to the controller of the view under the pointer.
    #
    # The Tk part is deliberately thin: everything about views and controllers is testable without a display.
    class GraphicsWindow
      extend MainThreadNew

      # Tk numbers the mouse buttons differently on a Mac (button 2 is the right one).
      BUTTON_NAMES = (MAC ? { 1 => :red, 2 => :blue, 3 => :yellow } : { 1 => :red, 2 => :yellow, 3 => :blue }).freeze

      attr_reader :view, :canvas, :window, :image

      def initialize(view, manager)
        @view = view
        @manager = manager
        @cursor = nil
        @closed = false
        @window = TkToplevel.new
        GUI.window_title(@window, view.label)
        GUI.place(@window)
        Tk.tk_call('wm', 'resizable', @window.path, '0', '0')
        build_canvas
        bind_events
        connect_view
        GUI.windows << self
      end

      # Show a freshly drawn Form (called on the main thread).
      def show_form(form)
        data = [form.to_png].pack('m0')
        Tk.tk_call(@image, 'configure', '-data', data)
      end

      private

      def build_canvas
        @canvas = TkCanvas.new(@window, width: @view.bounds.width, height: @view.bounds.height,
                                        highlightthickness: 0, background: 'white')
        @canvas.pack
        @image = Tk.tk_call('image', 'create', 'photo').to_s
        Tk.tk_call(@canvas.path, 'create', 'image', 0, 0, '-anchor', 'nw', '-image', @image)
      end

      # Tk events become ControlManager calls. The handler arguments are the event fields asked for
      # with the %-codes (as strings).
      def bind_events
        BUTTON_NAMES.each do |number, button|
          on("ButtonPress-#{number}", '%x', '%y') { |x, y| @manager.mouse_down(@view, x.to_i, y.to_i, button) }
          on("ButtonRelease-#{number}", '%x', '%y') { |x, y| @manager.mouse_up(@view, x.to_i, y.to_i, button) }
          on("B#{number}-Motion", '%x', '%y') { |x, y| @manager.mouse_move(@view, x.to_i, y.to_i) }
        end
        on('Motion', '%x', '%y') { |x, y| @manager.mouse_move(@view, x.to_i, y.to_i) }
        on('Leave') { @manager.mouse_leave(@view) }
        on('Enter') { @canvas.focus }
        on('KeyPress', '%K', '%A') { |keysym, char| @manager.key(@view, char.to_s, keysym.to_s) }
        @window.protocol('WM_DELETE_WINDOW') { GUI.safely { @manager.close(@view) } }
      end

      def on(event, *fields)
        @canvas.bind(event, *fields) do |*values|
          GUI.safely do
            yield(*values)
            apply_cursor
          end
        end
      end

      # The view calls these when it is redrawn or closed; they may come from the evaluator's thread.
      def connect_view
        @view.display_hook = ->(form) { GUI.on_main { show_form(form) } }
        @view.close_hook = lambda do
          GUI.on_main do
            next if @closed

            @closed = true
            @window.destroy
          end
        end
      end

      def apply_cursor
        name = @manager.cursor_name(@view)
        return if name == @cursor

        @cursor = name
        Tk.tk_call(@canvas.path, 'configure', '-cursor', name.dup)
      end
    end
  end
end
