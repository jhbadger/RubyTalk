# frozen_string_literal: true

require 'digest'

module RubyTalk
  # "Accept" in the browser, and replay of the changes file at startup.
  #
  # The text of the code pane is split into top-level statements. Each one is
  # evaluated and, if it succeeds, logged in the ChangeSet:
  #   class/module definition -> defined at the top level
  #   def name ... end        -> defined on the selected class (instance or class side)
  #   def self.name ... end   -> defined as a class method
  #   anything else           -> evaluated inside the selected class body
  #                              (attr_accessor, include, constants ...)
  module Compiler
    class Error < StandardError; end

    Outcome = Struct.new(:ok, :message, :klass, :side, :method_name, :error, keyword_init: true)

    module_function

    def accept(source, klass: nil, side: :instance, changes: RubyTalk.changes)
      error = Source.syntax_error(source, 'accept')
      return Outcome.new(ok: false, message: "SyntaxError: #{error.message}", error: error) if error

      statements = Source.split_statements(source)
      return Outcome.new(ok: false, message: 'Nothing to accept: the code pane has no code.') if statements.empty?

      outcome = nil
      Evaluator.with_transcript_io do
        statements.each { |statement| outcome = accept_statement(statement, klass, side, changes) }
      end
      outcome
    rescue *Evaluator::RECOVERABLE => e
      Outcome.new(ok: false, message: Evaluator.format_error(e), error: e)
    end

    def accept_statement(statement, klass, side, changes)
      description = Source.describe(statement)
      case description.kind
      when :class, :module
        define_toplevel(statement, description, changes)
      else
        raise Error, 'Select a class first, or write a complete class definition.' unless klass

        define_member(statement, description, klass, side, changes)
      end
    end

    def define_toplevel(statement, description, changes)
      name = description.name
      existing = Reflection.lookup(name)
      template = existing && Reflection.class_definition(existing).strip
      TOPLEVEL_BINDING.eval(statement, "rubytalk:#{name}", 1)
      klass = Reflection.lookup(name) or raise Error, "#{name} was not defined"

      if existing.nil? || changes.user_defined?(name)
        # A user-created class: its definition text is replaced in place.
        unless existing && statement.strip == template
          changes.record(kind: :class, target: name, source: statement, created: true)
        end
      elsif statement.strip != template
        changes.record(kind: :open, target: name, key: Digest::SHA1.hexdigest(statement)[0, 12], source: statement)
      end
      Outcome.new(ok: true, message: "#{description.kind} #{name} accepted", klass: klass, side: :instance)
    end

    def define_member(statement, description, klass, side, changes)
      target = Reflection.name_of(klass)
      case description.kind
      when :def
        kind = :method
        key = description.name
      when :defs
        kind = :method
        key = description.name
        side = :class
      else
        kind = :body
        key = Digest::SHA1.hexdigest(statement)[0, 12]
      end

      evaluate_member(statement, klass, side, description, "rubytalk:#{target}")
      changes.record(kind: kind, target: target, side: side, key: key, source: statement)
      sep = side == :class ? '.' : '#'
      message = kind == :method ? "#{target}#{sep}#{key} accepted" : "statement accepted in #{target}"
      Outcome.new(ok: true, message: message, klass: klass, side: side, method_name: kind == :method ? key : nil)
    end

    def evaluate_member(statement, klass, side, description, label)
      owner = description.kind == :defs || side != :class ? klass : klass.singleton_class
      owner.class_eval(statement, label, 1)
    end

    # Re-applies one logged change (startup).
    def replay(entry)
      Evaluator.with_transcript_io do
        case entry.kind
        when :class, :open
          TOPLEVEL_BINDING.eval(entry.source, "changes.rb:#{entry.target}", 1)
        when :method, :body
          klass = Reflection.lookup(entry.target) or raise NameError, "unknown class #{entry.target}"
          evaluate_member(entry.source, klass, entry.side, Source.describe(entry.source), "changes.rb:#{entry.target}")
        when :remove_method
          klass = Reflection.lookup(entry.target)
          if klass
            begin
              Reflection.owner_for(klass, entry.side).send(:remove_method, entry.key.to_sym)
            rescue NameError
              nil # already gone: fine
            end
          end
        end
      end
    end

    def remove_method(klass, side, name, changes)
      Reflection.owner_for(klass, side).send(:remove_method, name.to_sym)
      target = Reflection.name_of(klass)
      changes.delete_where { |e| e.kind == :method && e.target == target && e.side == side && e.key == name.to_s }
      changes.record(kind: :remove_method, target: target, side: side, key: name.to_s)
    end

    def remove_class(klass, changes)
      name = Reflection.name_of(klass)
      unless changes.user_defined?(name)
        raise Error, "#{name} is not a user-defined class; only classes created in RubyTalk can be removed."
      end

      parent_name, _, simple = name.rpartition('::')
      parent = parent_name.empty? ? Object : Reflection.lookup(parent_name)
      parent.send(:remove_const, simple.to_sym)
      changes.delete_for_class(name)
    end
  end
end
