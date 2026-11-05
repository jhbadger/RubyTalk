# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # A listbox that remembers a value per row and reports selection changes.
    #
    # Selection changes are detected on mouse-button release and key release
    # (plain, long-standing Tk events), rather than relying on a virtual event.
    class SelectableList
      attr_reader :frame, :box

      def initialize(parent, width: 20, height: 12, filter: false, on_filter: nil, &on_select)
        @on_select = on_select
        @values = []
        @index = nil
        @menu_items = []
        @frame = TkFrame.new(parent)
        build_filter(on_filter) if filter
        body = TkFrame.new(@frame)
        body.pack(side: 'top', fill: 'both', expand: 1)
        @box = TkListbox.new(body, width: width, height: height, exportselection: 0)
        bar = TkScrollbar.new(body)
        @box.yscrollbar(bar)
        bar.pack(side: 'right', fill: 'y')
        @box.pack(side: 'left', fill: 'both', expand: 1)
        @box.bind('ButtonRelease-1') { GUI.safely { poll } }
        @box.bind('KeyRelease') { GUI.safely { poll } }
        bind_popup
      end

      def filter_text
        @filter_var ? @filter_var.value.to_s : ''
      end

      def clear_filter
        @filter_var&.value = +''
      end

      # Replace the rows. +labels+ default to each value's to_s.
      def set(values, labels = nil)
        @box.delete(0, 'end')
        @values = values
        (labels || values.map(&:to_s)).each { |label| @box.insert('end', label.to_s.dup) }
        @index = nil
      end

      def selected_value
        @index && @values[@index]
      end

      # Right-click menu: array of [label, callable].
      def context_menu(items)
        @menu_items = items
      end

      def select_value(value, notify: true)
        index = @values.index(value)
        return false unless index

        select_index(index, notify: notify)
        true
      end

      def select_index(index, notify: true)
        @box.selection_clear(0, 'end')
        @box.selection_set(index)
        @box.see(index)
        @index = index
        @on_select.call(@values[index]) if notify
      end

      def clear_selection
        @box.selection_clear(0, 'end')
        @index = nil
      end

      private

      def build_filter(on_filter)
        @filter_var = TkVariable.new(+'')
        entry = TkEntry.new(@frame, textvariable: @filter_var)
        entry.pack(side: 'top', fill: 'x')
        entry.bind('KeyRelease') { GUI.safely { on_filter&.call } }
      end

      def poll
        raw = Array(@box.curselection).first
        index = raw.nil? || raw.to_s.empty? ? nil : raw.to_i
        return if index == @index

        @index = index
        @on_select.call(index && @values[index])
      end

      def bind_popup
        show = proc do
          next if @menu_items.empty? || @values.empty?

          pointer_y = Tk.tk_call('winfo', 'pointery', @box.path).to_i
          offset = Tk.tk_call('winfo', 'rooty', @box.path).to_i
          row = Tk.tk_call(@box.path, 'nearest', pointer_y - offset).to_i
          select_index(row) if row < @values.size && row != @index
          @popup&.destroy
          @popup = TkMenu.new(@box, tearoff: false)
          @menu_items.each { |label, action| GUI.add_item(@popup, label) { action.call } }
          GUI.popup(@popup)
        end
        %w[Button-2 Button-3 Control-Button-1].each do |event|
          @box.bind(event) do
            GUI.safely { show.call }
            Tk.callback_break
          end
        end
      end
    end
  end
end
