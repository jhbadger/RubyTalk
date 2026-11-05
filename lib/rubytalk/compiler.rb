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

    # What a method was before RubyTalk first overrode or removed it, so it can be
    # put back (even a built-in method written in C). +own+ is false when the
    # method was inherited: restoring then means removing the override.
    Original = Struct.new(:method, :visibility, :own)

    @originals = {}

    # { [class, side, "name"] => Original or nil (it did not exist before) }, for this process.
    def self.originals
      @originals
    end

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
      shown = existing && Reflection.class_definition(existing).strip # what the pane showed
      comment, body = Source.split_comment(statement)
      template = existing && Reflection.class_template(existing).strip # the definition without the comment
      TOPLEVEL_BINDING.eval(statement, "rubytalk:#{name}", 1)
      klass = Reflection.lookup(name) or raise Error, "#{name} was not defined"

      if existing.nil? || changes.user_defined?(name)
        # A user-created class: its definition text (comment included) is replaced in place.
        changes.record(kind: :class, target: name, source: statement, created: true) unless existing && statement.strip == shown
      elsif statement.strip == shown
        nil # nothing was changed
      elsif body.strip == template
        record_class_comment(klass, comment, changes) # only the comment above the class was edited
      else
        changes.record(kind: :open, target: name, key: Digest::SHA1.hexdigest(statement)[0, 12], source: statement)
      end
      Outcome.new(ok: true, message: "#{description.kind} #{name} accepted", klass: klass, side: :instance)
    end

    # The comment of a class that already existed. It is kept as a small reopen entry (the
    # comment above the unchanged definition) so it replays harmlessly. Writing the original
    # comment back, or clearing yours, removes the entry.
    def record_class_comment(klass, comment, changes)
      name = Reflection.name_of(klass)
      if comment.strip.empty? || comment == Reflection.file_comment(klass)
        changes.delete_where { |e| e.kind == :open && e.target == name && e.key == 'comment' }
      else
        changes.record(kind: :open, target: name, key: 'comment', source: "#{comment}#{Reflection.class_template(klass)}")
      end
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

      capture_original(klass, side, key) if kind == :method
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
          capture_original(klass, entry.side, entry.key) if entry.kind == :method
          evaluate_member(entry.source, klass, entry.side, Source.describe(entry.source), "changes.rb:#{entry.target}")
        when :remove_method
          klass = Reflection.lookup(entry.target)
          if klass
            capture_original(klass, entry.side, entry.key)
            begin
              Reflection.owner_for(klass, entry.side).send(:remove_method, entry.key.to_sym)
            rescue NameError
              nil # already gone: fine
            end
          end
        end
      end
    end

    # Remove a method. If RubyTalk had overridden a method that already existed, this puts the
    # original back (:reverted). A method you created is simply removed (:removed). Removing a
    # library method nobody overrode is logged in changes.rb so it persists (:removed); its
    # original stays available in the Versions window.
    # Returns :reverted or :removed.
    def remove_method(klass, side, name, changes)
      target = Reflection.name_of(klass)
      overridden = changes.find_method(target, side, name)
      capture_original(klass, side, name)
      original = originals[[klass, side, name.to_s]]
      return restore_original(klass, side, name, changes) && :reverted if overridden && original

      Reflection.owner_for(klass, side).send(:remove_method, name.to_sym)
      changes.delete_where { |e| e.kind == :method && e.target == target && e.side == side && e.key == name.to_s }
      changes.record(kind: :remove_method, target: target, side: side, key: name.to_s) if original || !overridden
      :removed
    end

    # Remember the method as it is now, unless we already have (or it does not exist yet).
    def capture_original(klass, side, name)
      key = [klass, side, name.to_s]
      return if originals.key?(key)

      owner = Reflection.owner_for(klass, side)
      originals[key] = begin
        method = owner.instance_method(name.to_sym)
        Original.new(method, visibility_of(owner, name.to_sym), method.owner == owner)
      rescue NameError
        nil
      end
    end

    def visibility_of(owner, name)
      if owner.private_method_defined?(name) then :private
      elsif owner.protected_method_defined?(name) then :protected
      else :public
      end
    end

    # Put the original method back and forget our override and any logged removal.
    def restore_original(klass, side, name, changes)
      original = originals[[klass, side, name.to_s]] or raise Error, "no original version of #{name} is known"
      owner = Reflection.owner_for(klass, side)
      symbol = name.to_sym
      if original.own
        owner.send(:define_method, symbol, original.method)
        owner.send(original.visibility, symbol)
      elsif owner.method_defined?(symbol, false) || owner.private_method_defined?(symbol, false)
        owner.send(:remove_method, symbol) # uncovers the inherited original
      end
      target = Reflection.name_of(klass)
      changes.delete_where do |e|
        e.target == target && e.side == side && e.key == name.to_s && %i[method remove_method].include?(e.kind)
      end
      true
    end

    # Go back to +version+ (a Reflection::Version). The version being replaced is kept in the
    # history, so a revert can itself be reverted. Returns an Outcome.
    def revert(klass, side, name, version, changes)
      if version.kind == :original
        restore_original(klass, side, name, changes)
        return Outcome.new(ok: true, message: "#{Reflection.name_of(klass)}##{name} restored to the original",
                           klass: klass, side: side, method_name: name.to_s)
      end
      accept(version.source, klass: klass, side: side, changes: changes)
    rescue Error => e
      Outcome.new(ok: false, message: e.message)
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
