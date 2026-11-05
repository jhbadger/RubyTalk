# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # Inspector: fields on the left, the selected field's value on the right,
    # and an evaluation pane at the bottom where `self` is the inspected object.
    # Double-click a field to inspect it in turn.
    class Inspector
      extend MainThreadNew

      MAX_ITEMS = 1000

      def initialize(object)
        @object = object
        @selected = object
        @fields = collect_fields(object)
        @window = TkToplevel.new
        GUI.window_title(@window, "Inspector: #{brief(object)}")
        GUI.place(@window)
        build
        GUI.build_menubar(@window, -> { @console })
        GUI.windows << self
        @list.select_index(0)
      end

      private

      def build
        panes = TkFrame.new(@window)
        panes.pack(side: 'top', fill: 'both', expand: 1)
        @list = SelectableList.new(panes, width: 28, height: 14) { |field| field_selected(field) }
        @list.frame.pack(side: 'left', fill: 'y')
        @list.set(@fields, @fields.map(&:first))
        @list.box.bind('Double-Button-1') { GUI.safely { open_selected } }
        @value = CodeEditor.new(panes, width: 64, height: 14, wrap: 'word', highlight: true,
                                       evaluator: ->(source) { Evaluator.evaluate_in(source, @selected) })
        @value.frame.pack(side: 'left', fill: 'both', expand: 1)
        @console = CodeEditor.new(@window, width: 92, height: 6, highlight: true,
                                           evaluator: ->(source) { Evaluator.evaluate_in(source, @object) })
        @console.frame.pack(side: 'top', fill: 'x')
        @console.set_contents("# self is the inspected object; try: #{MOD_LABEL}-P on the next line\nself")
      end

      def field_selected(field)
        return unless field

        @selected = field[1]
        @value.set_contents(GUI.print_string(@selected))
      end

      def open_selected
        field = @list.selected_value
        Inspector.new(field[1]) if field && field[0] != 'self'
      end

      def collect_fields(object)
        fields = [['self', object]]
        object.instance_variables.each { |name| fields << [name.to_s, object.instance_variable_get(name)] }
        case object
        when Array
          object.each_with_index.first(MAX_ITEMS).each { |value, index| fields << ["[#{index}]", value] }
        when Hash
          object.first(MAX_ITEMS).each { |key, value| fields << ["[#{brief(key, 40)}]", value] }
        when Struct
          object.each_pair { |name, value| fields << [name.to_s, value] }
        when Range
          fields << ['begin', object.begin] << ['end', object.end]
        else
          set_elements(object, fields)
        end
        fields
      end

      def set_elements(object, fields)
        return unless defined?(::Set) && object.is_a?(::Set)

        object.first(MAX_ITEMS).each_with_index { |value, index| fields << ["element #{index}", value] }
      end

      def brief(object, limit = 60)
        text = object.inspect
        text.size > limit ? "#{text[0, limit]}..." : text
      rescue StandardError
        object.class.to_s
      end
    end
  end
end
