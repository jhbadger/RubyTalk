# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # Where windows go, and remembering it between sessions (see Preferences). Mixed into GUI, so it
    # is used as GUI.place, GUI.save_layout and so on; the state lives in GUI's instance variables.
    module Layout
      def self.extended(gui)
        gui.instance_variable_set(:@cascade, 0)
        gui.instance_variable_set(:@layout_windows, []) # [window, kind] for every window of a remembered kind
        gui.instance_variable_set(:@kind_counts, Hash.new(0))
        gui.instance_variable_set(:@session_layout, nil)
      end

      # Where a new window goes. A kind of window (:browser, :workspace ...) that was open when you last
      # quit comes back at its remembered size and position (a second one of the same kind is nudged so
      # they do not coincide); otherwise windows are staggered so they do not stack exactly on top of
      # each other. Windows of a known kind remember their layout when closed or when you quit.
      def place(window, x: nil, y: nil, kind: nil)
        @layout_windows << [window, kind] if kind
        spec = kind && remembered_geometry(kind)
        if spec
          Tk.tk_call('wm', 'geometry', window.path, spec)
        else
          unless x
            step = @cascade % 8
            @cascade += 1
            x = 70 + (step * 28)
            y = 80 + (step * 28)
          end
          Tk.tk_call('wm', 'geometry', window.path, "+#{x}+#{y}")
        end
        window.protocol('WM_DELETE_WINDOW') { close_window(window, kind) } if kind && !window.is_a?(TkRoot)
      end

      # The saved size and position for +kind+, kept on screen, nudged for each further window of that
      # kind in this session. nil if there is none.
      def remembered_geometry(kind)
        saved = Preferences.layout[kind.to_s] or return nil

        count = (@kind_counts[kind] += 1) - 1
        width, height, x, y = saved.match(Preferences::GEOMETRY).captures.map(&:to_i)
        fit_on_screen(width, height, x + (count % 8) * 28, y + (count % 8) * 28)
      end

      # A geometry string with the window no bigger than the screen and at least a corner of it showing.
      def fit_on_screen(width, height, x, y)
        screen_width = Tk.tk_call('winfo', 'screenwidth', '.').to_i
        screen_height = Tk.tk_call('winfo', 'screenheight', '.').to_i
        width = [width, screen_width - 40].min
        height = [height, screen_height - 80].min
        x = x.clamp(-(width - 100), screen_width - 100)
        y = y.clamp(0, screen_height - 60)
        "#{width}x#{height}#{format('%+d', x)}#{format('%+d', y)}"
      end

      # WM_DELETE_WINDOW for these windows: remember where it was, then close it.
      def close_window(window, kind)
        remember_geometry(window, kind)
        window.destroy
      end

      def remember_geometry(window, kind)
        spec = Tk.tk_call('wm', 'geometry', window.path).to_s
        (@session_layout ||= {})[kind.to_s] = spec if spec.match?(Preferences::GEOMETRY)
      rescue StandardError
        nil
      end

      # Write the layout: for each kind, the geometry of the newest window still open, over what
      # closed windows left behind. Called when you quit or switch directory.
      def save_layout
        layout = (@session_layout || {}).dup
        @layout_windows.select! { |window, _kind| window_exists?(window) }
        @layout_windows.each { |window, kind| remember_geometry(window, kind) } # later windows overwrite earlier ones
        layout.merge!(@session_layout || {})
        Preferences.save_layout(layout) unless layout.empty?
      end

      def window_exists?(window)
        Tk.tk_call('winfo', 'exists', window.path).to_s == '1'
      rescue StandardError
        false
      end

      # For tests: forget which windows were opened and their remembered geometries.
      def reset_layout_state
        @layout_windows.clear
        @session_layout = nil
        @kind_counts.clear
      end
    end

    extend Layout
  end
end
