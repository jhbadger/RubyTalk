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
    #
    # With single: true (Spawn class) the class list holds just that one class: a browser
    # to work on one class without the rest of the system in the way.
    class Browser
      extend MainThreadNew

      def self.open(target = nil, method: nil, side: :instance, hierarchy: false, single: false)
        new(target, method: method, side: side, hierarchy: hierarchy, single: single)
      end

      attr_reader :code

      def initialize(target = nil, method: nil, side: :instance, hierarchy: false, single: false)
        @changes = RubyTalk.changes
        @catalog = Reflection.catalog(@changes)
        @category = @klass = @protocol = @method = nil
        @hierarchy_root = target if (hierarchy || single) && target.is_a?(Module) && Reflection.name_of(target)
        @single = single && !@hierarchy_root.nil?
        @window = TkToplevel.new
        GUI.window_title(@window, window_title_text)
        GUI.place(@window, kind: :browser)
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

      # Rebuild the category and class lists from the running system (e.g. after a Do it
      # that did `require 'bio'`), keeping the current selection.
      def reload
        @catalog = Reflection.catalog(@changes)
        if @hierarchy_root
          @hierarchy_rows = root_rows
        else
          @categories.set(@catalog.names)
          @categories.select_value(@category, notify: false) if @category
        end
        refresh_classes
      end

      # Reload every open browser, but only if classes or modules were added or removed
      # since +before+ (a value from Browser.module_count).
      def self.reload_all_if_changed(before)
        return if module_count == before

        GUI.windows.grep(Browser).each(&:reload)
      end

      def self.module_count
        counts = ObjectSpace.count_objects
        counts[:T_CLASS] + counts[:T_MODULE]
      end

      private

      def window_title_text
        return 'System Browser' unless @hierarchy_root

        "#{@single ? 'Class' : 'Hierarchy of'} #{Reflection.name_of(@hierarchy_root)}"
      end

      # The rows of the class list in hierarchy mode: the whole hierarchy, or just the one class.
      def root_rows
        @single ? [Reflection::HierarchyRow.new(@hierarchy_root, 0)] : Reflection.hierarchy(@hierarchy_root)
      end

      def open_on(target, method, side)
        if @hierarchy_root
          @hierarchy_rows = root_rows
          @categories.set([+"#{@single ? 'Class' : 'Hierarchy of'} #{Reflection.name_of(@hierarchy_root)}"])
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
        @classes.context_menu([['Run tests', -> { run_class_tests }],
                               ['New test class', -> { new_test_class }],
                               ['New subclass', -> { new_subclass }],
                               ['Hierarchy of this class', -> { show_hierarchy }],
                               ['Spawn class', -> { spawn_class }],
                               ['Versions of this class...', -> { show_class_versions }],
                               ['File out class...', -> { file_out_class }],
                               ['Remove class', -> { remove_class }]])
        @methods.context_menu([['Run this test', -> { run_test }],
                               ['Spawn method', -> { spawn_method }],
                               ['Versions...', -> { show_versions }],
                               ['Implementors of this selector', -> { selector_search(:implementors) }],
                               ['Senders of this selector', -> { selector_search(:senders) }],
                               ['Remove method', -> { remove_method }]])
        build_options
        @code = CodeEditor.new(@window, width: 100, height: 18, highlight: true,
                                        evaluator: ->(source) { Evaluator.evaluate(source, workspace_scope, file: 'browser') },
                                        scope: -> { [@klass, side] }, on_spawn: ->(text) { spawn_code(text) },
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
                               command: proc { GUI.safely { inherited_changed } }).pack(side: 'left', padx: 12)
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
                  (@category ? @catalog.classes_in(@category) : []).map { |mod| [mod, Reflection.list_label(mod)] }
                end
        needle = @classes.filter_text.strip.downcase
        pairs = pairs.select { |mod, _| Reflection.name_of(mod).downcase.include?(needle) } unless needle.empty?
        [pairs.map(&:first), pairs.map(&:last)]
      end

      def class_selected(klass)
        return load_pending(klass) if Reflection::Pending === klass

        @klass = klass
        @protocol = @method = nil
        @methods.set([])
        if klass.nil?
          @protocols.set([])
          return
        end
        refresh_protocols
        @code.set_contents(Reflection.class_definition(klass))
        status(Reflection.class_summary(klass))
      end

      # A class listed as "(not loaded)" was picked: run its autoload, then show the real thing.
      # If loading fails, say why and leave the entry in the list.
      def load_pending(pending)
        @klass = @protocol = @method = nil
        @protocols.set([])
        @methods.set([])
        status("Loading #{pending.name} ...")
        before = Browser.module_count
        loaded = Reflection.load_pending(pending)
        Browser.reload_all_if_changed(before)
        class_list_changed(loaded)
      rescue StandardError, ScriptError => e
        message = "Could not load #{pending.name} (#{pending.path}): #{e.class}: #{e.message.lines.first.to_s.strip}"
        status(message)
        ::Transcript.show_cr(message)
      end

      def protocol_selected(protocol)
        @protocol = protocol
        @method = nil
        refresh_methods
        return unless protocol

        @code.set_contents(Reflection.method_template(protocol))
        hint = protocol.is_a?(String) ? " in protocol #{protocol}" : ''
        status("New #{side} method#{hint} on #{Reflection.name_of(@klass)}: edit the template, then Accept.")
      end

      def method_selected(name)
        @method = name
        return unless name && @klass

        @code.set_contents(Reflection.method_text(@klass, side, name, @changes))
        status(Reflection.method_summary(@klass, side, name))
      end

      def side_changed
        @method = nil
        refresh_protocols
        refresh_methods
        @code.set_contents(Reflection.method_template(@protocol)) if @protocol
      end

      def inherited_changed
        refresh_protocols
        refresh_methods
      end

      # The protocol list for the selected class and side: your own protocols (`# protocol: name` comments)
      # between "all" and public/protected/private. Keeps the selected protocol if it is still there.
      def refresh_protocols
        return @protocols.set([]) unless @klass

        list = Reflection.protocol_list(@klass, side, inherited?, @changes)
        @protocols.set(list.map(&:last), list.map(&:first))
        @protocol = nil if @protocol && !@protocols.select_value(@protocol, notify: false)
      end

      def refresh_methods
        return @methods.set([]) unless @klass && @protocol

        names = Reflection.methods_for(@klass, side, @protocol, inherited?, @changes)
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
          @hierarchy_rows = root_rows
          select_in_hierarchy(klass, method: method, side: side)
        else
          @categories.set(@catalog.names)
          select_target(klass, method: method, side: side)
        end
      end

      def show_hierarchy
        Browser.open(@klass, hierarchy: true) if @klass
      end

      def file_out_class
        GUI.file_out_class(@klass) if @klass
      end

      # Spawn class: a new browser holding only this class.
      def spawn_class
        Browser.open(@klass, single: true) if @klass.is_a?(Module) && Reflection.name_of(@klass)
      end

      # Spawn method: the selected method in a window of its own (edits in the code pane come along).
      def spawn_method
        return unless @klass && @method

        spawn_code(@code.contents)
      end

      # Spawn the code pane. A method that is selected goes into its own method window, carrying any edits
      # not yet accepted, and the pane goes back to the stored source (nothing is lost: the edits are in
      # the new window). Anything else (a class definition, a new-method template) goes to a Workspace.
      def spawn_code(text)
        if @klass && @method && @protocol
          GUI.spawn_method(@klass, side, @method, text)
          method_selected(@method) if text != Reflection.method_text(@klass, side, @method, @changes)
        else
          GUI.spawn_workspace(text)
        end
      end

      def run_class_tests
        GUI.run_tests_for(@klass) if @klass
      end

      # Only for instance methods named test...: the Minitest convention.
      def run_test
        return unless @klass && @method
        return status('Select a method whose name starts with test.') unless side == :instance && @method.to_s.start_with?('test')

        GUI.run_test_method(@klass, @method)
      end

      def new_test_class
        return unless @klass

        @code.set_contents(Reflection.test_class_template(Reflection.name_of(@klass)))
        status('Edit the tests, then Accept to create the test class.')
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

      # Earlier definitions of the class (or its comment); a revert redisplays the class.
      def show_class_versions
        return unless @klass.is_a?(Module) && Reflection.name_of(@klass)

        VersionsWindow.new(@klass, :instance, nil, on_change: -> { class_selected(@klass) })
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
        refresh_protocols
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
          @hierarchy_rows = root_rows
          refresh_classes
        else
          @categories.set(@catalog.names)
          @categories.select_value(Reflection::USER)
        end
        status('Class removed.')
        GUI.close_window(@window, :browser) if @single
      rescue Compiler::Error => e
        status(e.message)
      end
    end
  end
end
