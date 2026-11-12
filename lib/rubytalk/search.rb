# frozen_string_literal: true

module RubyTalk
  # "Implementors of" and "Senders of", the two classic Smalltalk searches.
  #
  #   implementors  every class (instance or class side) that defines the method
  #   senders       every method whose source mentions the name (approximate; see
  #                 Source.mentions?). Searches methods defined in readable Ruby
  #                 files, plus everything recorded in changes.rb.
  module Search
    # What each method uses, kept between searches so the second "Senders of" does not read and lex
    # everything again. Nothing needs invalidating by hand:
    #   * a method in a file is keyed by [file, line] and the file's modification time, so editing the
    #     file makes the entry stale (it is looked up again);
    #   * what RubyTalk recorded in changes.rb is keyed by the source text itself, so an Accept simply
    #     produces a new key.
    # Both are emptied when they grow past MAX_CACHED.
    MAX_CACHED = 60_000
    @method_names = {} # [file, line] => [mtime, Set of names]
    @change_names = {} # source text => Set of names

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

    # Forget what is remembered (for tests, and for anyone who wants to measure a cold search).
    def clear_caches
      @method_names.clear
      @change_names.clear
    end

    # How many methods and changes are remembered: [methods, changes].
    def cache_sizes
      [@method_names.size, @change_names.size]
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
      target = Source.mention_name(name) or return []

      changes.entries.filter_map do |entry|
        next unless entry.source && change_names(entry.source).include?(target)

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
      target = Source.mention_name(name) or return []

      base = name.chomp('=')
      reader = FileReader.new
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

            names = names_used_by(method, base, reader) or next
            hits << Hit.new(mod, side, method_name.to_s) if names.include?(target)
          end
        end
      end
      hits
    end

    # Reads each file at most once per search, and asks for its modification time once.
    class FileReader
      def initialize
        @mtimes = {}
        @texts = {}
        @lines = {}
      end

      # nil if +file+ is not a readable file.
      def mtime(file)
        return @mtimes[file] if @mtimes.key?(file)

        @mtimes[file] = begin
          File.file?(file) ? File.mtime(file) : nil
        rescue SystemCallError
          nil
        end
      end

      def text(file)
        @texts[file] = Search.read_text(file) unless @texts.key?(file)
        @texts[file]
      end

      def lines(file)
        @lines[file] ||= text(file).lines
      end
    end

    # The names used by the source of +method+, or nil if it has no readable Ruby source or its file
    # cannot mention +base+ (the file is not even parsed then, which skips almost all of them).
    def names_used_by(method, base, reader)
      file, line = method.source_location
      return nil unless file && (mtime = reader.mtime(file))

      key = [file, line]
      cached = @method_names[key]
      return cached[1] if cached && cached[0] == mtime
      return nil unless reader.text(file)&.include?(base)

      source = Source.extract_from_lines(reader.lines(file), line - 1) or return nil
      @method_names.clear if @method_names.size >= MAX_CACHED
      (@method_names[key] = [mtime, Source.mention_set(source)])[1]
    end

    def change_names(source)
      @change_names[source] ||= begin
        @change_names.clear if @change_names.size >= MAX_CACHED
        Source.mention_set(source)
      end
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
