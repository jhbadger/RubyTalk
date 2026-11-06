# frozen_string_literal: true

require 'fileutils'

module RubyTalk
  # The change log: every class definition, method definition and method
  # removal made through the browser, in order. This is the Smalltalk
  # "changes file" idea. It is replayed at startup and written back on exit.
  #
  # File format (changes.rb): plain text, one chunk per change. A chunk starts
  # with a header comment line and runs until the next header:
  #
  #   #!rubytalk kind=method target=Point side=instance key=distance at=2026-11-05T12:00:00Z
  #   def distance(other)
  #     ...
  #   end
  #
  # changes.rb holds only the latest version of each method. When a method is
  # redefined or removed, the old version is appended to changes.history (same
  # chunk format), which feeds the "Versions" window.
  class ChangeSet
    KINDS = %i[class open method body remove_method].freeze
    HEADER = /\A#!rubytalk\s+(.*)\z/.freeze
    PREAMBLE = <<~TEXT
      # RubyTalk changes file.
      # Replayed in order when RubyTalk starts in this directory, and rewritten when it exits.
      # Each chunk begins with a '#!rubytalk' header line; edit with care.
    TEXT

    # kind:    :class (new class), :open (reopen existing class), :method,
    #          :body (other class-body statement), :remove_method
    # created: true for classes that did not exist before this change
    # at:      when it was recorded (UTC, ISO 8601), nil for entries from older files
    Entry = Struct.new(:kind, :target, :side, :key, :source, :created, :failed, :at) do
      def identity
        case kind
        when :class then [:class, target]
        when :open then [:open, target, key]
        else [kind, target, side, key]
        end
      end

      def to_s
        sep = side == :class ? '.' : '#'
        key ? "#{kind} #{target}#{sep}#{key}" : "#{kind} #{target}"
      end
    end

    # Most versions of one method kept for the Versions window.
    MAX_VERSIONS = 100

    attr_reader :path, :entries, :history

    # When true, every change is written to disk as soon as it is recorded
    # (Smalltalk logs each change immediately), so a crash loses nothing.
    attr_accessor :autosave

    def initialize(path = nil)
      @path = path
      @entries = []
      @dirty = false
      @autosave = false
      @backed_up = false
      @history = []          # replaced/removed methods, oldest first
      @history_pending = []  # not yet appended to the history file
    end

    # Where replaced versions are kept: changes.rb -> changes.history.
    def history_path
      @path && "#{@path.sub(/\.rb\z/, '')}.history"
    end

    # Earlier versions of a method (not the current one), newest first.
    def versions(target, side, key)
      @history.select { |e| e.target == target && e.side == side && e.key == key.to_s }
              .reverse.first(MAX_VERSIONS)
    end

    def dirty?
      @dirty
    end

    # Adds a change, or replaces the earlier change with the same identity.
    def record(kind:, target:, side: :instance, key: nil, source: nil, created: false)
      entry = Entry.new(kind, target, side, key, source, created, false, Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'))
      # Defining a method again cancels an earlier removal of the same method.
      @entries.reject! { |e| e.identity == [:remove_method, target, side, key] } if kind == :method
      existing = @entries.index { |e| e.identity == entry.identity }
      if existing
        archive(@entries[existing]) if @entries[existing].source != source
        @entries[existing] = entry
      else
        @entries << entry
      end
      @dirty = true
      persist
      entry
    end

    def delete_where
      before = @entries.size
      removed, @entries = @entries.partition { |entry| yield entry }
      return if @entries.size == before

      removed.each { |entry| archive(entry) }
      @dirty = true
      persist
    end

    def delete_for_class(name)
      delete_where { |e| e.target == name || e.target.start_with?("#{name}::") }
    end

    def find_method(target, side, key)
      @entries.find { |e| e.kind == :method && e.target == target && e.side == side && e.key == key.to_s }
    end

    # A reopen entry by key; "comment" holds a class's comment (see Compiler).
    def open_entry(target, key)
      @entries.find { |e| e.kind == :open && e.target == target && e.key == key }
    end

    def class_entry(name)
      @entries.find { |e| e.kind == :class && e.target == name }
    end

    # Was this class (or an enclosing class) created through RubyTalk?
    def user_defined?(name)
      @entries.any? do |e|
        e.kind == :class && e.created && (name == e.target || name.start_with?("#{e.target}::"))
      end
    end

    # --- Reading ------------------------------------------------------------

    def self.parse(text)
      entries = []
      current = nil
      body = []
      finish = lambda do
        next unless current

        current.source = "#{body.join.sub(/\A(?:[ \t]*\n)+/, '').rstrip}\n"
        entries << current
      end

      text.each_line do |line|
        match = HEADER.match(line.chomp)
        if match
          finish.call
          current = entry_from_header(match[1])
          body = []
        elsif current
          body << line
        end
      end
      finish.call
      entries
    end

    def self.entry_from_header(header)
      attrs = header.split(/\s+/).to_h { |token| token.split('=', 2) }
      kind = attrs['kind']&.to_sym
      return nil unless KINDS.include?(kind)

      Entry.new(kind, attrs['target'], (attrs['side'] || 'instance').to_sym, attrs['key'], nil,
                attrs['created'] == 'true', false, attrs['at'])
    end

    # Loads and replays the file. A chunk that fails is reported to the
    # Transcript and kept (so saving never silently drops it).
    def load!
      load_history
      return 0 unless @path && File.file?(@path)

      @entries = self.class.parse(File.read(@path, encoding: 'UTF-8')).compact
      applied = 0
      @entries.each do |entry|
        Compiler.replay(entry)
        applied += 1
      rescue *Evaluator::RECOVERABLE => e
        entry.failed = true
        ::Transcript.show_cr("#{File.basename(@path)}: could not apply #{entry}: #{e.class}: #{e.message.lines.first&.strip}")
      end
      @dirty = false
      ::Transcript.show_cr("Loaded #{applied} of #{@entries.size} changes from #{@path}")
      applied
    end

    # --- Writing ------------------------------------------------------------

    def to_text
      chunks = @entries.map { |entry| chunk_text(entry) }
      ([PREAMBLE] + chunks).join("\n") << "\n"
    end

    # Writes the file if anything changed this session. Returns the path, or nil
    # when there was nothing to write.
    def save!
      return nil unless @path
      return nil unless @dirty || (!File.exist?(@path) && !@entries.empty?)

      # Keep one backup per session: the file exactly as it was at startup.
      if File.exist?(@path) && !@backed_up
        FileUtils.cp(@path, "#{@path}.bak")
        @backed_up = true
      end
      temporary = "#{@path}.tmp"
      File.write(temporary, to_text, encoding: 'UTF-8')
      File.rename(temporary, @path)
      flush_history
      @dirty = false
      @path
    end

    private

    # Autosave must never break an Accept: if the disk write fails, say so once
    # and fall back to saving on exit.
    def persist
      save! if @autosave
    rescue SystemCallError => e
      @autosave = false
      ::Transcript.show_cr("changes.rb autosave disabled (#{e.class}: #{e.message}); will retry when you quit.")
    end

    # Remember a method version that is about to be replaced or removed.
    def archive(entry)
      return unless entry.kind == :method && entry.source

      @history << entry
      @history_pending << entry
    end

    def load_history
      path = history_path
      return unless path && File.file?(path)

      @history = self.class.parse(File.read(path, encoding: 'UTF-8')).compact
    end

    def flush_history
      return if @history_pending.empty? || history_path.nil?

      File.open(history_path, 'a', encoding: 'UTF-8') do |file|
        @history_pending.each { |entry| file.write("#{chunk_text(entry)}\n") }
      end
      @history_pending.clear
    end

    def chunk_text(entry)
      "#{header_line(entry)}\n#{entry.source.to_s.rstrip}\n"
    end

    def header_line(entry)
      parts = ["kind=#{entry.kind}", "target=#{entry.target}"]
      parts << "side=#{entry.side}" if %i[method body remove_method].include?(entry.kind)
      parts << "key=#{entry.key}" if entry.key
      parts << 'created=true' if entry.created
      parts << "at=#{entry.at}" if entry.at
      "#!rubytalk #{parts.join(' ')}"
    end
  end
end
