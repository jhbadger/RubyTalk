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
  # changes.rb holds only the latest version of each method and class definition. When one is
  # redefined or removed, the old version is appended to changes.history (same chunk format),
  # which feeds the "Versions" window.
  #
  # Nothing in the file is ever dropped silently:
  #   * a chunk that fails to replay is reported and kept (and tried again next start);
  #   * a chunk this version does not understand (an unknown kind, a damaged header) is kept
  #     exactly as it was written;
  #   * a file written by a NEWER format than this one is read, but never rewritten.
  # The file is written to a temporary file and renamed into place, so a crash while saving
  # leaves the old file whole.
  class ChangeSet
    KINDS = %i[class open method body remove_method].freeze
    HEADER = /\A#!rubytalk\s+(.*)\z/.freeze
    # Bumped when the chunk format changes in a way older versions cannot read. Files without a
    # format line (written before it existed) are format 1.
    FORMAT_VERSION = 1
    FORMAT_LINE = /\A#\s*format:\s*(\d+)/.freeze
    PREAMBLE = <<~TEXT
      # RubyTalk changes file.
      # format: #{FORMAT_VERSION}
      # Replayed in order when RubyTalk starts in this directory, and rewritten when it exits.
      # Each chunk begins with a '#!rubytalk' header line; edit with care.
    TEXT

    # kind:    :class (new class), :open (reopen existing class), :method,
    #          :body (other class-body statement), :remove_method
    # created: true for classes that did not exist before this change
    # at:      when it was recorded (UTC, ISO 8601), nil for entries from older files
    # raw_header: only for a chunk this version cannot interpret; it is written back verbatim.
    Entry = Struct.new(:kind, :target, :side, :key, :source, :created, :failed, :at, :raw_header) do
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

    # The format number found in the file at load (nil: no file or no format line), and whether the
    # file is from a newer RubyTalk. A newer file is read but never overwritten.
    attr_reader :file_format

    def newer_format?
      !@file_format.nil? && @file_format > FORMAT_VERSION
    end

    # When true, every change is written to disk as soon as it is recorded
    # (Smalltalk logs each change immediately), so a crash loses nothing.
    attr_accessor :autosave

    def initialize(path = nil)
      @path = path
      @entries = []
      @dirty = false
      @autosave = false
      @backed_up = false
      @file_format = nil
      @read_only_warned = false
      @history = []          # replaced/removed methods, oldest first
      @history_pending = []  # not yet appended to the history file
    end

    # Where replaced versions are kept: changes.rb -> changes.history.
    def history_path
      @path && "#{@path.sub(/\.rb\z/, '')}.history"
    end

    # Earlier versions of a method (not the current one), newest first.
    def versions(target, side, key)
      @history.select { |e| e.kind == :method && e.target == target && e.side == side && e.key == key.to_s }
              .reverse.first(MAX_VERSIONS)
    end

    # Earlier versions of a class's definition (a class created in RubyTalk) or of its comment (a class
    # that already existed), not the current one, newest first. A class-body statement (attr_accessor,
    # include ...) is its own entry, identified by its text, so editing one makes a new statement, not a
    # new version of the old one; replaced and removed statements are still archived.
    def class_versions(target)
      @history.select { |e| e.target == target && (e.kind == :class || (e.kind == :open && e.key == 'comment')) }
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

    # The "# format: N" line of a changes file, or nil if it has none (an older file).
    def self.format_of(text)
      text.each_line do |line|
        break if HEADER.match?(line.chomp)

        match = FORMAT_LINE.match(line)
        return match[1].to_i if match
      end
      nil
    end

    # A header this version cannot interpret (unknown kind, damaged) still becomes an entry, marked
    # failed and carrying its header text, so it is written back exactly as found instead of vanishing.
    def self.entry_from_header(header)
      attrs = header.split(/\s+/).to_h do |token|
        name, value = token.split('=', 2)
        [name, value]
      end
      kind = attrs['kind']&.to_sym
      return Entry.new(kind || :unknown, attrs['target'], :instance, attrs['key'], nil, false, true, attrs['at'], header) unless KINDS.include?(kind)

      Entry.new(kind, attrs['target'], (attrs['side'] || 'instance').to_sym, attrs['key'], nil,
                attrs['created'] == 'true', false, attrs['at'])
    end

    # Loads and replays the file. A chunk that fails is reported to the Transcript and kept (so
    # saving never silently drops it); #failed_entries lists them.
    def load!
      load_history
      return 0 unless @path && File.file?(@path)

      text = File.read(@path, encoding: 'UTF-8')
      @file_format = self.class.format_of(text)
      @entries = self.class.parse(text).compact
      warn_newer_format
      applied = 0
      @entries.each do |entry|
        replay_entry(entry)
        applied += 1
      rescue *Evaluator::RECOVERABLE => e
        entry.failed = true
        ::Transcript.show_cr("#{File.basename(@path)}: could not apply #{entry}: #{e.class}: #{e.message.lines.first&.strip}")
      end
      @dirty = false
      ::Transcript.show_cr("Loaded #{applied} of #{@entries.size} changes from #{@path}")
      report_failures
      applied
    end

    # The entries that did not replay at the last load (still in the file, tried again next start).
    def failed_entries
      @entries.select(&:failed)
    end

    # --- Writing -----------------------------------------------------------

    def to_text
      chunks = @entries.map { |entry| chunk_text(entry) }
      ([PREAMBLE] + chunks).join("\n") << "\n"
    end

    # Writes the file if anything changed this session. Returns the path, or nil when there was
    # nothing to write (or the file is from a newer RubyTalk and must not be overwritten).
    #
    # The new text goes to changes.rb.tmp, is flushed to disk, and only then renamed over the real
    # file, so the file on disk is always either the old one or the new one, whole. If anything goes
    # wrong the temporary file is removed and the error raised; the changes stay unsaved in memory
    # (dirty), and the next save tries again.
    def save!
      return nil unless @path
      return nil unless @dirty || (!File.exist?(@path) && !@entries.empty?)
      return refuse_newer_format if newer_format?

      # Keep one backup per session: the file exactly as it was at startup.
      if File.exist?(@path) && !@backed_up
        FileUtils.cp(@path, "#{@path}.bak")
        @backed_up = true
      end
      write_atomically(@path, to_text)
      flush_history
      @dirty = false
      @path
    end

    private

    def write_atomically(path, text)
      temporary = "#{path}.tmp"
      File.open(temporary, 'w', encoding: 'UTF-8') do |file|
        file.write(text)
        file.flush
        file.fsync
      end
      File.rename(temporary, path)
    rescue StandardError
      FileUtils.rm_f(temporary)
      raise
    end

    def replay_entry(entry)
      raise ArgumentError, "unknown kind of change (#{entry.raw_header.to_s[0, 60]}): written by a newer RubyTalk?" if entry.raw_header

      Compiler.replay(entry)
    end

    def warn_newer_format
      return unless newer_format?

      ::Transcript.show_cr("#{File.basename(@path)} is format #{@file_format}, newer than this RubyTalk understands " \
                           "(format #{FORMAT_VERSION}). It is loaded as far as possible but will NOT be overwritten.")
    end

    # Said once, when a save is refused.
    def refuse_newer_format
      return nil if @read_only_warned

      @read_only_warned = true
      ::Transcript.show_cr("Not saving #{File.basename(@path)}: it was written by a newer RubyTalk (format " \
                           "#{@file_format}). Your latest changes are in memory only: use System > File Out Changes as Ruby.")
      nil
    end

    def report_failures
      failed = failed_entries
      return if failed.empty?

      ::Transcript.show_cr("WARNING: #{failed.size} of #{@entries.size} changes could not be applied. They are still in " \
                           "#{File.basename(@path)} and will be tried again next time; fix or remove them there.")
      failed.each { |entry| ::Transcript.show_cr("  not applied: #{entry}") }
    end

    # Autosave must never break an Accept: if the disk write fails, say so once
    # and fall back to saving on exit.
    def persist
      save! if @autosave
    rescue SystemCallError => e
      @autosave = false
      ::Transcript.show_cr("changes.rb autosave disabled (#{e.class}: #{e.message}); will retry when you quit.")
    end

    # Remember a version (of a method, class definition, comment or statement) that is about to be
    # replaced or removed.
    def archive(entry)
      return unless entry.source

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
      return "#!rubytalk #{entry.raw_header}" if entry.raw_header

      parts = ["kind=#{entry.kind}", "target=#{entry.target}"]
      parts << "side=#{entry.side}" if %i[method body remove_method].include?(entry.kind)
      parts << "key=#{entry.key}" if entry.key
      parts << 'created=true' if entry.created
      parts << "at=#{entry.at}" if entry.at
      "#!rubytalk #{parts.join(' ')}"
    end
  end
end
