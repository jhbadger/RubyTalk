# frozen_string_literal: true

require 'time'

module RubyTalk
  # Everything the System Browser needs to know about classes and methods,
  # with no GUI involved so it can be tested headlessly.
  module Reflection
    USER = 'User-Defined'
    ALL = 'All Classes'

    # Smalltalk-style class categories for the built-in library.
    CATEGORY_TABLE = [
      ['Kernel-Objects', %w[BasicObject Object Kernel Module Class NilClass TrueClass FalseClass Comparable
                            Method UnboundMethod Proc Binding ObjectSpace GC Marshal Signal Refinement Data]],
      ['Numbers', %w[Numeric Integer Float Rational Complex Math Random BigDecimal Prime]],
      ['Text', %w[String Symbol Regexp MatchData Encoding]],
      ['Collections', %w[Array Hash Range Set Struct Enumerable Enumerator]],
      ['Streams-Files', %w[IO File Dir FileTest StringIO Pathname Tempfile FileUtils]],
      ['Time-Process', %w[Time Date DateTime Process]],
      ['Concurrency', %w[Thread Mutex Queue SizedQueue ConditionVariable Fiber Ractor Monitor Timeout]]
    ].freeze

    CATEGORY_OF = CATEGORY_TABLE.each_with_object({}) do |(category, names), map|
      names.each { |name| map[name] = category }
    end.freeze

    PROTOCOLS = [['-- all --', :all], %w[public public], %w[protected protected], %w[private private]]
                .map { |label, key| [label, key.to_sym] }.freeze

    MODULE_NAME = Module.instance_method(:name)

    Catalog = Struct.new(:groups, :names) do
      def classes_in(category)
        if category == ALL
          groups.values.flatten.sort_by { |mod| Reflection.name_of(mod) }
        else
          groups.fetch(category, [])
        end
      end
    end

    module_function

    def name_of(mod)
      MODULE_NAME.bind_call(mod)
    end

    def lookup(name)
      return nil if name.nil? || name.empty?

      object = Object.const_get(name)
      object.is_a?(Module) ? object : nil
    rescue NameError, LoadError
      nil
    end

    # Is +mod+ still reachable by its own name? A class removed with remove_const keeps
    # its name for as long as anything refers to it, but it is no longer part of the system.
    def listed?(mod)
      name = name_of(mod)
      !name.nil? && lookup(name).equal?(mod)
    end

    def all_modules
      modules = []
      ObjectSpace.each_object(Module) { |mod| modules << mod if listed?(mod) }
      modules.sort_by { |mod| name_of(mod) }
    end

    def category_of(mod, changes = RubyTalk.changes)
      name = name_of(mod)
      return USER if changes&.user_defined?(name)

      top = name.split('::').first
      category = CATEGORY_OF[name] || CATEGORY_OF[top]
      return category if category
      return 'Exceptions' if mod.is_a?(Class) && mod <= Exception
      return "Nested: #{top}" if name.include?('::')

      mod.is_a?(Class) ? 'Other' : 'Modules'
    end

    def catalog(changes = RubyTalk.changes)
      groups = Hash.new { |hash, key| hash[key] = [] }
      groups[USER]
      all_modules.each { |mod| groups[category_of(mod, changes)] << mod }
      order = [USER] + CATEGORY_TABLE.map(&:first) + %w[Exceptions Modules Other]
      names = (order & groups.keys) + (groups.keys - order).sort
      Catalog.new(groups, names + [ALL])
    end

    # --- Classes ------------------------------------------------------------

    # One line of a hierarchy: a class or module and how far it is indented.
    HierarchyRow = Struct.new(:klass, :depth) do
      def label
        "#{'  ' * depth}#{Reflection.name_of(klass)}"
      end
    end

    # Hierarchy lists stop here (the subclasses of Object alone number in the hundreds).
    MAX_HIERARCHY = 3000

    # The Smalltalk hierarchy view of +klass+:
    #   a class   -> its superclass chain from BasicObject down to it, then ALL its
    #                subclasses below it, each level indented one step more;
    #   a module  -> the module, then the classes and modules that include it directly.
    def hierarchy(klass)
      rows = []
      if klass.is_a?(Class)
        chain = []
        current = klass
        while current
          chain.unshift(current)
          current = current.superclass
        end
        chain.each_with_index { |ancestor, depth| rows << HierarchyRow.new(ancestor, depth) }
        add_subclasses(klass, chain.size, children_by_parent, rows)
      else
        rows << HierarchyRow.new(klass, 0)
        direct_includers(klass).each { |includer| rows << HierarchyRow.new(includer, 1) }
      end
      rows.first(MAX_HIERARCHY)
    end

    # { parent class => [named subclasses, sorted by name] }, built in one pass.
    def children_by_parent
      children = Hash.new { |hash, key| hash[key] = [] }
      ObjectSpace.each_object(Class) do |klass|
        next if klass.singleton_class? || !listed?(klass)

        parent = klass.superclass
        children[parent] << klass if parent
      end
      children.each_value { |list| list.sort_by! { |klass| name_of(klass) } }
      children
    end

    def add_subclasses(klass, depth, children, rows)
      children.fetch(klass, []).each do |child|
        break if rows.size >= MAX_HIERARCHY

        rows << HierarchyRow.new(child, depth)
        add_subclasses(child, depth + 1, children, rows)
      end
    end

    # Classes and modules that include +mod+ themselves (not through a superclass).
    def direct_includers(mod)
      includers = all_modules.select do |candidate|
        next false if candidate.equal?(mod) || !candidate.include?(mod)

        !(candidate.is_a?(Class) && candidate.superclass&.include?(mod))
      end
      includers.sort_by { |candidate| name_of(candidate) }
    end

    # What the browser shows for a class: its comment (the # lines above `class`), then the
    # definition. A class created in RubyTalk shows exactly the text it was accepted with.
    def class_definition(klass)
      entry = RubyTalk.changes&.class_entry(name_of(klass))
      return entry.source if entry&.created

      "#{class_comment(klass)}#{class_template(klass)}"
    end

    # The class comment: yours if you edited it (kept in changes.rb), else the RDoc comment above
    # the class in its source file when it was written in Ruby, else "". Ends in a newline.
    def class_comment(klass, changes = RubyTalk.changes)
      entry = changes&.open_entry(name_of(klass), 'comment')
      entry ? Source.split_comment(entry.source).first : file_comment(klass)
    end

    # Lines that are tool settings, not documentation.
    MAGIC_COMMENT = /\A#\s*(-\*-|frozen_string_literal|encoding|coding|warn_indent|shareable_constant_value)/.freeze

    def file_comment(klass)
      name = name_of(klass) or return ''
      file, line = Object.const_source_location(name)
      return '' unless file && line && File.file?(file)

      comment = Source.leading_comments(File.readlines(file, encoding: 'UTF-8'), line - 1)
      comment.lines.reject { |text| text.match?(MAGIC_COMMENT) }.first(40).join
    rescue NameError, SystemCallError, EncodingError, ArgumentError
      ''
    end

    # `class Foo < Bar` plus the modules it adds, with no comment.
    def class_template(klass)
      name = name_of(klass)
      return "module #{name}\nend\n" unless klass.is_a?(Class)

      superclass = klass.superclass
      header = "class #{name}"
      header += " < #{name_of(superclass) || 'Object'}" if superclass
      inherited = superclass ? superclass.included_modules : []
      mixins = (klass.included_modules - inherited).filter_map { |mod| name_of(mod) }
      body = mixins.reverse.map { |mod| "  include #{mod}\n" }.join
      "#{header}\n#{body}end\n"
    end

    def new_class_template(superclass_name = 'Object')
      "# Describe NewClass here.\nclass NewClass < #{superclass_name}\nend\n"
    end

    # A starting point for tests of +name+ (see TestRunner for how they are found).
    def test_class_template(name)
      "# Tests for #{name}.\nclass #{name}Test < Minitest::Test\n  def test_something\n    assert true\n  end\nend\n"
    end

    def class_summary(klass)
      kind = klass.is_a?(Class) ? 'class' : 'module'
      origin = RubyTalk.changes&.user_defined?(name_of(klass)) ? 'user-defined' : 'built-in or loaded library'
      "#{kind} #{name_of(klass)} (#{origin}); ancestors: #{klass.ancestors.first(6).map { |a| name_of(a) }.compact.join(', ')}"
    end

    # --- Methods ------------------------------------------------------------

    def owner_for(klass, side)
      side == :class ? klass.singleton_class : klass
    end

    def methods_for(klass, side, protocol, inherited)
      owner = owner_for(klass, side)
      names = case protocol
              when :public then owner.public_instance_methods(inherited)
              when :protected then owner.protected_instance_methods(inherited)
              when :private then owner.private_instance_methods(inherited)
              else
                owner.public_instance_methods(inherited) +
                owner.protected_instance_methods(inherited) +
                owner.private_instance_methods(inherited)
              end
      names.uniq.sort_by(&:to_s)
    end

    def method_object(klass, side, name)
      owner_for(klass, side).instance_method(name.to_sym)
    rescue NameError
      nil
    end

    # [class name, side] for a method owner, or nil if it is anonymous.
    def owner_target(owner)
      return [name_of(owner), :instance] if name_of(owner)
      return nil unless owner.singleton_class?

      attached = owner.respond_to?(:attached_object) ? owner.attached_object : lookup(owner.inspect[/\A#<Class:(.+)>\z/, 1])
      attached.is_a?(Module) && name_of(attached) ? [name_of(attached), :class] : nil
    end

    def owner_label(owner)
      target = owner_target(owner)
      return owner.inspect unless target

      target[1] == :class ? "#{target[0]} (class side)" : target[0]
    end

    # List label: methods changed through RubyTalk get a leading "* ".
    def method_label(klass, side, name, changes = RubyTalk.changes)
      changed = changes&.find_method(name_of(klass), side, name)
      changed ? "* #{name}" : name.to_s
    end

    def method_template
      "def method_name(arg)\n  # comment\n  \nend\n"
    end

    def method_text(klass, side, name, changes = RubyTalk.changes)
      method = method_object(klass, side, name)
      return method_template unless method

      target, owner_side = owner_target(method.owner)
      entry = target && changes&.find_method(target, owner_side, name)
      return entry.source if entry

      text_for_method(method, side, name)
    end

    # The text to show for a method object: its Ruby source (with where it came
    # from), or a description of a C method.
    def text_for_method(method, side, name)
      source = Source.method_source(method)
      return "# #{method.source_location.join(':')}\n#{source}" if source

      builtin_description(method, side, name)
    end

    # One entry of the Versions window. kind: :current, :previous or :original.
    Version = Struct.new(:kind, :label, :source, :at)

    # The versions of a method, newest first: the current RubyTalk definition (if any),
    # earlier ones from changes.history, then the original library method (if RubyTalk
    # has overridden or removed one in this session).
    def versions(klass, side, name, changes = RubyTalk.changes)
      target = name_of(klass)
      list = []
      current = changes&.find_method(target, side, name)
      list << Version.new(:current, "Current#{when_label(current.at)}", current.source, current.at) if current
      (changes&.versions(target, side, name) || []).each do |entry|
        lines = entry.source.lines.size
        list << Version.new(:previous, "#{when_label(entry.at, '')}  (#{lines} line#{'s' unless lines == 1})",
                            entry.source, entry.at)
      end
      original = Compiler.originals[[klass, side, name.to_s]]
      if original
        list << Version.new(:original, 'Original (library)', text_for_method(original.method, side, name), nil)
      end
      list
    end

    # " - 2026-11-05 12:03" in local time; "earlier session" when unknown.
    def when_label(iso, prefix = ' - ')
      return "#{prefix}earlier session" unless iso

      "#{prefix}#{Time.iso8601(iso).localtime.strftime('%Y-%m-%d %H:%M')}"
    rescue ArgumentError
      "#{prefix}earlier session"
    end

    def method_summary(klass, side, name)
      method = method_object(klass, side, name)
      return '' unless method

      "#{owner_label(method.owner)}##{name}  (arity #{method.arity})"
    end

    def builtin_description(method, side, name)
      sep = side == :class ? '.' : '#'
      params = parameter_list(method.parameters)
      <<~TEXT
        # #{owner_label(method.owner)}#{sep}#{name} is implemented in C: no Ruby source is available.
        # arity: #{method.arity}   parameters: #{method.parameters.inspect}
        # To override it, uncomment and complete the definition below, then Accept.
        #
        # def #{name}#{params.empty? ? '' : "(#{params})"}
        #   super
        # end
      TEXT
    end

    def parameter_list(parameters)
      parameters.each_with_index.map do |(type, name), index|
        name = nil if %i[* ** &].include?(name)
        fallback = name || "arg#{index + 1}"
        case type
        when :req then fallback.to_s
        when :opt then "#{fallback} = nil"
        when :rest then name ? "*#{name}" : '*args'
        when :keyreq then "#{name}:"
        when :key then "#{name}: nil"
        when :keyrest then name ? "**#{name}" : '**options'
        when :block then name ? "&#{name}" : '&block'
        when :nokey then '**nil'
        else name.to_s
        end
      end.join(', ')
    end
  end
end
