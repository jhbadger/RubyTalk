# frozen_string_literal: true

module RubyTalk
  # File out and file in: moving code between RubyTalk and plain .rb files, with no GUI.
  #
  #   file out  your changes as ordinary Ruby you can `load`, `require` or send to someone: classes
  #             with their methods grouped, class-side methods inside `class << self`, removals as
  #             guarded lines. changes.rb itself is a log in RubyTalk's own format; this is the
  #             readable export of it.
  #   file in   a plain .rb file, taken apart so each method becomes a change you can browse, version
  #             and revert, or a file in RubyTalk's own changes format (as written by System > Show
  #             Changes), which is replayed and recorded as it is.
  module Exchange
    # What a file in did. +errors+ lists what could not be done (one line each).
    class Summary
      attr_accessor :classes, :methods, :statements, :top_level
      attr_reader :errors

      def initialize
        @classes = 0
        @methods = 0
        @statements = 0
        @top_level = 0
        @errors = []
      end

      def ok?
        @errors.empty?
      end

      def to_s
        parts = ["#{@classes} class#{'es' unless @classes == 1} created", "#{@methods} method#{'s' unless @methods == 1}",
                 "#{@statements} other class statement#{'s' unless @statements == 1}",
                 "#{@top_level} top-level statement#{'s' unless @top_level == 1} run"]
        text = parts.join(', ')
        @errors.empty? ? text : "#{text}; #{@errors.size} error#{'s' unless @errors.size == 1}"
      end
    end

    # A class or module header on one line, with at most a constant for a superclass: `class Foo < Bar`.
    SIMPLE_HEADER = /\A(?:class|module)\s+[\w:]+(?:\s*<\s*[\w:]+)?\s*(?:#.*)?\z/.freeze

    module_function

    # --- File out -----------------------------------------------------------

    # Everything in +changes+ as plain Ruby.
    def all_source(changes = RubyTalk.changes)
      render(changes.entries)
    end

    # Just +klass+'s changes as plain Ruby, or nil if nothing was recorded for it.
    def class_source(klass, changes = RubyTalk.changes)
      name = Reflection.name_of(klass)
      entries = changes.entries.select { |entry| entry.target == name }
      entries.empty? ? nil : render(entries)
    end

    def render(entries)
      sections = []
      group = nil
      flush = lambda do
        sections << wrap(group) if group
        group = nil
      end
      entries.each do |entry|
        case entry.kind
        when :class, :open
          flush.call
          sections << entry.source.rstrip
        when :remove_method
          flush.call
          sections << removal(entry)
        when :method, :body
          key = [entry.target, wrapper_kind(entry)]
          if group && group[:key] == key
            group[:sources] << entry.source
          else
            flush.call
            group = { key: key, target: entry.target, kind: key[1], sources: [entry.source] }
          end
        end
      end
      flush.call
      "#{file_out_header}\n\n#{sections.join("\n\n")}\n"
    end

    def file_out_header
      "# Filed out from RubyTalk #{RubyTalk::VERSION} on #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}.\n" \
        '# Plain Ruby: load or require it, or file it in with RubyTalk (System > File In...).'
    end

    # Class-side definitions are written inside `class << self`, except `def self.x` which is
    # already a class-side definition when written in the class body.
    def wrapper_kind(entry)
      entry.side == :class && Source.describe(entry.source).kind != :defs ? :singleton : :instance
    end

    def wrap(group)
      keyword = module_named?(group[:target]) ? 'module' : 'class'
      singleton = group[:kind] == :singleton
      body = group[:sources].map { |source| indent(source.rstrip, singleton ? 4 : 2) }.join("\n\n")
      if singleton
        "#{keyword} #{group[:target]}\n  class << self\n#{body}\n  end\nend"
      else
        "#{keyword} #{group[:target]}\n#{body}\nend"
      end
    end

    def module_named?(name)
      mod = Reflection.lookup(name)
      !mod.nil? && !mod.is_a?(Class)
    end

    # Indent every line, unless the text has a heredoc (indenting would change its contents).
    def indent(text, spaces)
      return text if text.match?(/<<[~-]?['"]?\w/)

      pad = ' ' * spaces
      text.lines.map { |line| line.strip.empty? ? line : "#{pad}#{line}" }.join
    end

    def removal(entry)
      owner = entry.side == :class ? "#{entry.target}.singleton_class" : entry.target
      name = entry.key.to_sym.inspect
      "#{owner}.send(:remove_method, #{name}) if #{owner}.method_defined?(#{name}, false) || " \
        "#{owner}.private_method_defined?(#{name}, false)"
    end

    # --- File in ------------------------------------------------------------

    # File in +text+ (plain Ruby, or RubyTalk's own changes format). Returns a Summary.
    # +label+ names the source in error messages.
    def file_in(text, changes = RubyTalk.changes, label: 'source')
      summary = Summary.new
      if text.match?(/^#!rubytalk\b/)
        file_in_native(text, changes, summary)
      else
        file_in_ruby(text, changes, summary, label)
      end
      summary
    end

    def file_in_path(path, changes = RubyTalk.changes)
      file_in(File.read(path, encoding: 'UTF-8'), changes, label: File.basename(path))
    end

    # RubyTalk's own format: replay each chunk and record it as it is.
    def file_in_native(text, changes, summary)
      ChangeSet.parse(text).compact.each do |entry|
        Compiler.replay(entry)
        changes.record(kind: entry.kind, target: entry.target, side: entry.side, key: entry.key,
                       source: entry.source, created: entry.created)
        case entry.kind
        when :class then summary.classes += 1
        when :method then summary.methods += 1
        else summary.statements += 1
        end
      rescue *Evaluator::RECOVERABLE => e
        summary.errors << "#{entry}: #{e.class}: #{e.message.lines.first&.strip}"
      end
    end

    def file_in_ruby(text, changes, summary, label)
      error = Source.syntax_error(text, label)
      return summary.errors << "SyntaxError: #{error.message.lines.first&.strip}" if error

      Source.split_statements(text).each do |raw|
        statement = tidy(raw)
        description = Source.describe(statement)
        if %i[class module].include?(description.kind)
          file_in_class(statement, description, changes, summary)
        else
          run_top_level(statement, summary, label)
        end
      end
    end

    # A class or module: when it is written the ordinary way (a one-line header, `end` last) it is taken
    # apart so each method becomes its own change; otherwise it is accepted as one statement.
    def file_in_class(statement, description, changes, summary)
      comment, rest = Source.split_comment(statement)
      lines = rest.lines
      return file_in_whole(statement, changes, summary) unless lines.size >= 2 && lines.last.strip == 'end' &&
                                                               lines.first.strip.match?(SIMPLE_HEADER)

      klass = Reflection.lookup(description.name)
      unless klass
        outcome = Compiler.accept("#{comment}#{lines.first.chomp}\nend\n", changes: changes)
        return note(summary, outcome) unless outcome.ok

        klass = outcome.klass
        summary.classes += 1
      end
      Source.split_statements(lines[1...-1].join).each { |member| file_in_member(tidy(member), klass, changes, summary) }
    end

    # A statement as it will be stored: no blank lines in front, and its own indentation removed
    # (members of a class body arrive indented, and are indented again when filed out).
    def tidy(statement)
      Source.dedent(statement.sub(/\A(?:[ \t]*\n)+/, ''))
    end

    def file_in_whole(statement, changes, summary)
      outcome = Compiler.accept(statement, changes: changes)
      outcome.ok ? summary.classes += 1 : note(summary, outcome)
    end

    def file_in_member(statement, klass, changes, summary)
      description = Source.describe(statement)
      if %i[def defs].include?(description.kind)
        outcome = Compiler.accept(statement, klass: klass, side: :instance, changes: changes)
        outcome.ok ? summary.methods += 1 : note(summary, outcome)
      elsif singleton_block?(statement)
        file_in_singleton(statement, klass, changes, summary)
      else
        outcome = Compiler.accept_body(statement, klass, :instance, changes)
        outcome.ok ? summary.statements += 1 : note(summary, outcome)
      end
    end

    def singleton_block?(statement)
      _comment, rest = Source.split_comment(statement)
      lines = rest.lines
      lines.size >= 2 && lines.last.strip == 'end' && lines.first.strip.match?(/\Aclass\s*<<\s*self\s*(?:#.*)?\z/)
    end

    # `class << self ... end`: each statement inside is a class-side change.
    def file_in_singleton(statement, klass, changes, summary)
      _comment, rest = Source.split_comment(statement)
      Source.split_statements(rest.lines[1...-1].join).each do |raw|
        member = tidy(raw)
        description = Source.describe(member)
        outcome = if %i[class module].include?(description.kind)
                    Compiler.accept_body(member, klass, :class, changes)
                  else
                    Compiler.accept(member, klass: klass, side: :class, changes: changes)
                  end
        next note(summary, outcome) unless outcome.ok

        description.kind == :def ? summary.methods += 1 : summary.statements += 1
      end
    end

    # Code outside any class (requires, puts, helpers): run it, but it is not recorded as a change.
    def run_top_level(statement, summary, label)
      Evaluator.with_transcript_io { TOPLEVEL_BINDING.eval(statement, label, 1) }
      summary.top_level += 1
    rescue *Evaluator::RECOVERABLE => e
      summary.errors << "#{label}: #{e.class}: #{e.message.lines.first&.strip}"
    end

    def note(summary, outcome)
      summary.errors << outcome.message.to_s.lines.first.to_s.strip
    end
  end
end
