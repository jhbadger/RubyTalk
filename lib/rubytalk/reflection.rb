# frozen_string_literal: true

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
    rescue NameError
      nil
    end

    def all_modules
      modules = []
      ObjectSpace.each_object(Module) { |mod| modules << mod if name_of(mod) }
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

    def class_definition(klass)
      name = name_of(klass)
      entry = RubyTalk.changes&.class_entry(name)
      return entry.source if entry&.created

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
      "class NewClass < #{superclass_name}\n  # comment\nend\n"
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

      source = Source.method_source(method)
      return "# #{method.source_location.join(':')}\n#{source}" if source

      builtin_description(method, side, name)
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
