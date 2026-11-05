# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # The System Browser, in the Smalltalk-80 layout:
    #
    #   category | class | protocol | method
    #   ---------------------------------------
    #   code pane (class definition, method source, or a template)
    #
    # Selecting a category shows a template for a new class; a class shows its
    # definition; a protocol shows a template for a new method; a method shows
    # its source. Accept (Cmd-S / Ctrl-S) compiles whatever is in the code pane
    # and logs it in changes.rb. Right-click lists for remove / new subclass.
    #
    # With hierarchy: true the class list is the hierarchy of one class instead of a
    # category: its superclass chain from BasicObject, then all its subclasses, each
    # level indented. Everything else works the same (browse, accept, versions ...).
    class Browser
      extend MainThreadNew

      def self.open(target = nil, method: nil, side: :instance, hierarchy: false)
        new(target, method: method, side: side, hierarchy: hierarchy)
      end

      attr_reader :code

      def initialize(target = nil, method: nil, side: :instance, hierarchy: false)
        @changes = RubyTalk.changes
        @catalog = Reflection.catalog(@changes)
        @category = @klass = @protocol = @method = nil
        @hierarchy_root = target if hierarchy && target.is_a?(Module) && Reflection.name_of(target)
        @window = TkToplevel.new
        GUI.window_title(@window, @hierarchy_root ? "Hierarchy of #{Reflection.name_of(@hierarchy_root)}" : 'System Browser')
        GUI.place(@window)
        build
        GUI.build_menubar(@window, -> { @code })
        GUI.windows << self
        open_on(target, method, side)
      end

      # Navigate to a class (and optionally one of its methods).
      def select_target(klass, method: nil, side: :instance)
        @classes.clear_filter
        @categories.select_value(Reflection.category_of(klass, @changes))
        @classes.select_value(klass)
        @side_var.value = side.to_s.dup
        return unless method

        @protocols.select_value(:all)
        @methods.select_value(method.to_sym)
      end

      private

      def open_on(target, method, side)
        if @hierarchy_root
          @hierarchy_rows = Reflection.hierarchy(@hierarchy_root)
          @categories.set([+"Hierarchy of #{Reflection.name_of(@hierarchy_root)}"])
          @categories.select_index(0)
          select_in_hierarchy(target, method: method, side: side)
        else
          @categories.set(@catalog.names)
          select_target(target, method: method, side: side) if target.is_a?(Module) && Reflection.name_of(target)
        end
      end

      # Hierarchy mode's version of select_target.
      def select_in_hierarchy(klass, method: nil, side: :instance)
        @classes.clear_filter
        refresh_classes
        @classes.select_value(klass)
        @side_var.value = side.to_s.dup
        return unless method

        @protocols.select_value(:all)
        @methods.select_value(method.to_sym)
      end

      def build
        panes = TkFrame.new(@window)
        panes.pack(side: 'top', fill: 'both', expand: 1)
        @categories = pane(panes, 18) { |value| category_selected(value) }
        @classes = pane(panes, 26, filter: true) { |value| class_selected(value) }
        @protocols = pane(panes, 14) { |value| protocol_selected(value) }
        @methods = pane(panes, 28) { |value| method_selected(value) }
        @classes.context_menu([['New subclass', -> { new_subclass }],
                               ['Hierarchy of this class', -> { show_hierarchy }],
                               ['Remove class', -> { remove_class }]])
        @methods.context_menu([['Versions...', -> { show_versions }],
                               ['Implementors of this selector', -> { selector_search(:implementors) }],
                               ['Senders of this selector', -> { selector_search(:senders) }],
                               ['Remove method', -> { remove_method }]])
        build_options
        @code = CodeEditor.new(@window, width: 100, height: 18, highlight: true,
                                        evaluator: ->(source) { Evaluator.evaluate(source, workspace_scope, file: 'browser') },
                                        on_accept: -> { accept })
        @code.frame.pack(side: 'top', fill: 'both', expand: 1)
      end

      def pane(parent, width, filter: false, &on_select)
        list = SelectableList.new(parent, width: width, height: 12, filter: filter,
                                          on_filter: -> { refresh_classes }, &on_select)
        list.frame.pack(side: 'left', fill: 'both', expand: 1)
        list
      end

      def build_options
        @side_var = TkVariable.new(+'instance')
        @inherited_var = TkVariable.new(0)
        bar = TkFrame.new(@window)
        bar.pack(side: 'top', fill: 'x')
        %w[instance class].each do |side|
          TkRadiobutton.new(bar, text: side, variable: @side_var, value: side,
                                 command: proc { GUI.safely { side_changed } }).pack(side: 'left', padx: 4)
        end
        TkCheckButton.new(bar, text: 'show inherited', variable: @inherited_var,
                               command: proc { GUI.safely { refresh_methods } }).pack(side: 'left', padx: 12)
        @status = TkLabel.new(bar, text: +'', anchor: 'w')
        @status.pack(side: 'left', fill: 'x', expand: 1, padx: 8)
      end

      def workspace_scope
        @workspace_scope ||= Evaluator.new_binding
      end

      def side
        @side_var.value.to_s == 'class' ? :class : :instance
      end

      def inherited?
        @inherited_var.value.to_s == '1'
      end

      def status(message)
        @status.configure(text: message.to_s.dup)
      end

      # --- selection handlers -------------------------------------------

      def category_selected(name)
        @category = name
        @klass = @protocol = @method = nil
        refresh_classes
        @protocols.set([])
        @methods.set([])
        @code.set_contents(name ? Reflection.new_class_template : '')
        status(name ? 'Edit the class definition, then Accept to create a class.' : '')
      end

      def refresh_classes
        modules, labels = visible_classes
        @classes.set(modules, labels)
        @classes.select_value(@klass, notify: false) if @klass
      end

      # The class list: the selected category, or the hierarchy rows; narrowed by the filter box.
      def visible_classes
        pairs = if @hierarchy_root
                  @hierarchy_rows.map { |row| [row.klass, row.label] }
                else
                  (@category ? @catalog.classes_in(@category) : []).map { |mod| [mod, Reflection.name_of(mod)] }
                end
        needle = @classes.filter_text.strip.downcase
        pairs = pairs.select { |mod, _| Reflection.name_of(mod).downcase.include?(needle) } unless needle.empty?
        [pairs.map(&:first), pairs.map(&:last)]
      end

      def class_selected(klass)
        @klass = klass
        @protocol = @method = nil
        @methods.set([])
        if klass.nil?
          @protocols.set([])
          return
        end
        @protocols.set(Reflection::PROTOCOLS.map(&:last), Reflection::PROTOCOLS.map(&:first))
        @code.set_contents(Reflection.class_definition(klass))
        status(Reflection.class_summary(klass))
      end

      def protocol_selected(protocol)
        @protocol = protocol
        @method = nil
        refresh_methods
        return unless protocol

        @code.set_contents(Reflection.method_template)
        status("New #{side} method on #{Reflection.name_of(@klass)}: edit the template, then Accept.")
      end

      def method_selected(name)
        @method = name
        return unless name && @klass

        @code.set_contents(Reflection.method_text(@klass, side, name, @changes))
        status(Reflection.method_summary(@klass, side, name))
      end

      def side_changed
        @method = nil
        refresh_methods
        @code.set_contents(Reflection.method_template) if @protocol
      end

      def refresh_methods
        return @methods.set([]) unless @klass && @protocol

        names = Reflection.methods_for(@klass, side, @protocol, inherited?)
        labels = names.map { |name| Reflection.method_label(@klass, side, name, @changes) }
        @methods.set(names, labels)
        @methods.select_value(@method, notify: false) if @method
      end

      # --- commands -----------------------------------------------------

      def accept
        outcome = Compiler.accept(@code.contents, klass: @klass, side: side, changes: @changes)
        unless outcome.ok
          status("Not accepted: #{outcome.message.to_s.lines.first.to_s.strip}")
          ::Transcript.show_cr(outcome.message)
          return
        end
        class_list_changed(outcome.klass, method: outcome.method_name, side: outcome.side)
        status(outcome.message)
      end

      # Classes were added or removed: rebuild the lists and go to +klass+.
      def class_list_changed(klass, method: nil, side: :instance)
        @catalog = Reflection.catalog(@changes)
        if @hierarchy_root
          @hierarchy_rows = Reflection.hierarchy(@hierarchy_root)
          select_in_hierarchy(klass, method: method, side: side)
        else
          @categories.set(@catalog.names)
          select_target(klass, method: method, side: side)
        end
      end

      def show_hierarchy
        Browser.open(@klass, hierarchy: true) if @klass
      end

      def show_versions
        return unless @klass && @method

        VersionsWindow.new(@klass, side, @method, on_change: -> { versions_changed })
      end

      # A revert in the Versions window: show the method as it is now.
      def versions_changed
        refresh_methods
        method_selected(@method) if @method
      end

      def selector_search(kind)
        GUI.show_method_list(kind, @method.to_s) if @method
      end

      def new_subclass
        return unless @klass

        @code.set_contents(Reflection.new_class_template(Reflection.name_of(@klass)))
        status('Edit the new class name, then Accept.')
      end

      def remove_method
        return unless @klass && @method
        return unless GUI.confirm("Remove #{Reflection.name_of(@klass)}##{@method}?\n\n" \
                                  'The version you remove stays available under Versions.')

        result = Compiler.remove_method(@klass, side, @method, @changes)
        @method = nil unless result == :reverted
        refresh_methods
        if result == :reverted
          method_selected(@method)
          status('Restored the original method.')
        else
          @code.set_contents(Reflection.method_template)
          status('Method removed.')
        end
      rescue NameError => e
        status("Cannot remove: #{e.message.lines.first.to_s.strip}")
      end

      def remove_class
        return unless @klass
        return unless GUI.confirm("Remove class #{Reflection.name_of(@klass)} and all its changes?")

        removed = @klass
        Compiler.remove_class(removed, @changes)
        @catalog = Reflection.catalog(@changes)
        if @hierarchy_root
          @klass = nil
          @hierarchy_root = Object if removed.equal?(@hierarchy_root)
          @hierarchy_rows = Reflection.hierarchy(@hierarchy_root)
          refresh_classes
        else
          @categories.set(@catalog.names)
          @categories.select_value(Reflection::USER)
        end
        status('Class removed.')
      rescue Compiler::Error => e
        status(e.message)
      end
    end
  end
end
