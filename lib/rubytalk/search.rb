# frozen_string_literal: true

module RubyTalk
  # "Implementors of" and "Senders of", the two classic Smalltalk searches.
  #
  #   implementors  every class (instance or class side) that defines the method
  #   senders       every method whose source mentions the name (approximate; see
  #                 Source.mentions?). Searches methods defined in readable Ruby
  #                 files, plus everything recorded in changes.rb.
  module Search
    # +name+ is nil for class-body statements (shown as "Class (class body)").
    # +source+ is set when the text to display is not the method's own source.
    Hit = Struct.new(:klass, :side, :name, :source) do
      def label
        class_name = Reflection.name_of(klass)
        return "#{class_name} (class body)" unless name

        "#{class_name}#{side == :class ? '.' : '#'}#{name}"
      end
    end

    module_function

    def implementors(selector)
      name = selector.to_s
      symbol = name.to_sym
      hits = []
      Reflection.all_modules.each do |mod|
        %i[instance class].each do |side|
          owner = singleton_or_self(mod, side) or next
          hits << Hit.new(mod, side, name) if defines?(owner, symbol)
        end
      end
      sort(hits)
    end

    def senders(selector, changes = RubyTalk.changes)
      name = selector.to_s
      hits = changes ? senders_in_changes(name, changes) : []
      hits.concat(senders_in_files(name))
      sort(hits)
    end

    def sort(hits)
      hits.sort_by { |hit| [Reflection.name_of(hit.klass), hit.side.to_s, hit.name.to_s] }
    end

    def singleton_or_self(mod, side)
      Reflection.owner_for(mod, side)
    rescue TypeError
      nil
    end

    def defines?(owner, symbol)
      owner.method_defined?(symbol, false) || owner.private_method_defined?(symbol, false)
    end

    def senders_in_changes(name, changes)
      changes.entries.filter_map do |entry|
        next unless entry.source && Source.mentions?(entry.source, name)

        klass = Reflection.lookup(entry.target) or next
        case entry.kind
        when :method then Hit.new(klass, entry.side, entry.key)
        else Hit.new(klass, entry.side, nil, entry.source)
        end
      end
    end

    # Walks every method defined in Ruby source files. A file is only parsed
    # when its raw text contains the name at all, which skips almost all of them.
    def senders_in_files(name)
      base = name.chomp('=')
      texts = {}
      lines = {}
      hits = []
      Reflection.all_modules.each do |mod|
        %i[instance class].each do |side|
          owner = singleton_or_self(mod, side) or next
          own_methods(owner).each do |method_name|
            method = begin
              owner.instance_method(method_name)
            rescue NameError
              next
            end
            next unless method.owner == owner

            file, line = method.source_location
            next unless file && File.file?(file)

            texts[file] = read_text(file) unless texts.key?(file)
            next unless texts[file]&.include?(base)

            lines[file] ||= texts[file].lines
            source = Source.extract_from_lines(lines[file], line - 1)
            hits << Hit.new(mod, side, method_name.to_s) if source && Source.mentions?(source, name)
          end
        end
      end
      hits
    end

    def own_methods(owner)
      owner.public_instance_methods(false) + owner.protected_instance_methods(false) +
        owner.private_instance_methods(false)
    end

    def read_text(file)
      File.read(file, encoding: 'UTF-8')
    rescue SystemCallError, EncodingError
      nil
    end
  end
end
