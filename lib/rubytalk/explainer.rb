# frozen_string_literal: true

module RubyTalk
  # "Explain it": say what a word in a code pane is, without running anything.
  #
  # Smalltalk-80 (and Squeak's Cmd-E) answers in a fixed order, and so does this:
  #
  #   keyword (self, nil, yield ...)
  #   local variable or parameter    -> where it is declared in the pane's text
  #   @instance variable             -> which methods of the class use it
  #   @@class variable, $global      -> its current value
  #   Constant                       -> the class or module: superclass, source file, comment
  #   anything else (a selector)     -> the method, if the pane's class has it, and who implements it
  #
  # Nothing here touches Tk: the GUI only passes in the word and asks for the text.
  module Explainer
    KEYWORDS = {
      'self' => 'the receiver of the message being run: the object whose method this is',
      'super' => "calls the same method as defined by the superclass (or the next module in the ancestors)",
      'nil' => 'the only instance of NilClass: "no object", and false in a condition',
      'true' => 'the only instance of TrueClass',
      'false' => 'the only instance of FalseClass',
      'yield' => "runs the block the method was called with, passing it the arguments given here",
      'block_given?' => 'true if the current method was called with a block',
      'return' => 'ends the method and answers a value (the last expression is answered anyway)',
      'end' => 'closes the nearest def, class, module, do, if, while, case or begin',
      'raise' => 'signals an exception; it unwinds the stack until a rescue takes it',
      'require' => 'loads a library once; classes it defines then appear in the browser'
    }.freeze

    # One word or token of Ruby: instance/class/global variables, symbols, constants (qualified), names.
    TOKEN = /@@\w+|@\w+|\$(?:\w+|[!@&`'+~=\/\\,;.<>_0*$?:"])|:[A-Za-z_]\w*[?!=]?|[A-Z]\w*(?:::[A-Z]\w*)*|[a-z_]\w*[?!]?|\[\]=?|<=>|===?|=~|!=|<<|>>|<=|>=|\*\*|[-+*\/%<>!~^&|]/.freeze

    # How many implementors to list.
    MAX_LISTED = 12

    module_function

    # The token that covers +column+ (0-based) of +line+, or nil. A cursor just after a word counts as
    # being in it, so the word you just typed can be explained without selecting it.
    def token_at(line, column)
      line.to_enum(:scan, TOKEN).map { Regexp.last_match }.find do |match|
        column >= match.begin(0) && column <= match.end(0)
      end&.to_s
    end

    # Text explaining +word+. +source+ is the text of the pane (for local variables); +klass+ and +side+
    # say which class the pane is about (a browser's selected class), or nil.
    def explain(word, source: nil, klass: nil, side: :instance)
      word = word.to_s.strip
      return 'Nothing to explain: select a word, or put the cursor in one.' if word.empty?
      return 'Select one word to explain (a variable, class or method name).' if word.match?(/\s/)

      explain_word(word, source.to_s, klass, side)
    end

    def explain_word(word, source, klass, side)
      case word
      when /\A@@/ then explain_class_variable(word, klass)
      when /\A@/ then explain_instance_variable(word, klass, side)
      when /\A\$/ then explain_global(word)
      when /\A:(.+)\z/ then "#{word} is a Symbol.\n#{explain_word(Regexp.last_match(1), source, klass, side)}"
      when /\A[A-Z]/ then explain_constant(word, klass)
      else explain_lowercase(word, source, klass, side)
      end
    end

    def explain_lowercase(word, source, klass, side)
      return "#{word}: #{KEYWORDS[word]}." if KEYWORDS.key?(word)

      local = local_declaration(word, source)
      return local if local

      explain_selector(word, klass, side)
    end

    # --- local variables ------------------------------------------------------

    # "x is a parameter of method m (line 1)" / "x is a local variable, first assigned on line 3", or nil
    # if the text does not declare +name+ (then it is a message to self: a selector).
    def local_declaration(name, source)
      sexp = Ripper.sexp(source) or return nil
      found = find_declaration(sexp, name, nil)
      return nil unless found

      kind, line, owner = found
      where = owner ? " of #{owner}" : ''
      case kind
      when :param then "#{name} is a parameter#{where} (line #{line}): a local variable holding an argument."
      when :block_param then "#{name} is a block parameter#{where} (line #{line}): local to the block."
      else "#{name} is a local variable#{where}, first assigned on line #{line}."
      end
    end

    # Depth-first, so the first declaration in reading order is the one reported.
    # Returns [kind, line, "method m" or nil] or nil.
    def find_declaration(node, name, owner)
      return nil unless node.is_a?(Array)

      case node[0]
      when :def, :defs
        owner = "method #{node[node[0] == :def ? 1 : 3][1]}"
        found = declared_in_params(node[node[0] == :def ? 2 : 4], name, :param, owner)
        return found if found
      when :block_var
        found = declared_in_params(node, name, :block_param, owner)
        return found if found
      when :var_field # the target of =, op-assign, rescue => e, multiple assignment
        ident = node[1]
        return [:assigned, ident[2][0], owner] if ident.is_a?(Array) && ident[0] == :@ident && ident[1] == name
      end
      node.each do |child|
        found = find_declaration(child, name, owner)
        return found if found
      end
      nil
    end

    def declared_in_params(params, name, kind, owner)
      hit = param_names(params).find { |declared, _line| declared == name }
      hit ? [kind, hit[1], owner] : nil
    end

    # [[name, line], ...] declared by a parameter list. Default-value expressions are skipped, so
    # `def m(a, b = foo)` declares a and b but not foo.
    def param_names(node, found = [])
      return found unless node.is_a?(Array)

      case node[0]
      when :@ident then found << [node[1], node[2][0]]
      when :@label then found << [node[1].chomp(':'), node[2][0]]
      when :params
        node[1..].each { |part| param_part(part, found) }
      else
        node.each { |child| param_names(child, found) }
      end
      found
    end

    # One slot of a :params node: nil, a list (required, optional, keyword ...) or a single rest/block param.
    def param_part(part, found)
      return unless part.is_a?(Array)

      if part.first.is_a?(Symbol)
        param_names(part, found)
      else
        part.each { |item| param_names(item.is_a?(Array) && item.first.is_a?(Array) ? item.first : item, found) }
      end
    end

    # --- variables ------------------------------------------------------------

    def explain_instance_variable(word, klass, side)
      return "#{word} is an instance variable: private state of one object. Pick a class in the browser to see which methods use it." unless klass

      owner = Reflection.owner_for(klass, side)
      users = own_methods_mentioning(owner, word)
      who = Reflection.name_of(klass)
      who += ' (class side)' if side == :class
      text = "#{word} is an instance variable of #{who}"
      text += side == :class ? " (a class-level variable of the class object itself)." : '.'
      text += "\nUsed by: #{users.join(', ')}" unless users.empty?
      reader = word.delete_prefix('@')
      text += "\nReader method #{reader} exists." if owner.method_defined?(reader)
      text += "\nWriter method #{reader}= exists." if owner.method_defined?("#{reader}=")
      text
    end

    def explain_class_variable(word, klass)
      if klass && klass.class_variable_defined?(word)
        "#{word} is a class variable of #{Reflection.name_of(klass)}, shared with its subclasses.\nValue: #{brief(klass.class_variable_get(word))}"
      else
        "#{word} is a class variable: one value shared by a class and its subclasses."
      end
    end

    def explain_global(word)
      if global_variables.include?(word.to_sym)
        # The name matched TOKEN and is a known global, so evaluating it only reads it.
        "#{word} is a global variable.\nValue: #{brief(TOPLEVEL_BINDING.eval(word))}"
      else
        "#{word} is a global variable, but nothing has assigned it (it is nil)."
      end
    end

    # A short, safe inspect for explanations.
    def brief(value)
      text = value.inspect
      text.size > 200 ? "#{text[0, 200]}..." : text
    rescue StandardError => e
      "(inspect failed: #{e.class})"
    end

    # Names of methods defined directly on +owner+ whose source mentions the variable +word+.
    def own_methods_mentioning(owner, word)
      names = Search.own_methods(owner).select do |name|
        method = begin
          owner.instance_method(name)
        rescue NameError
          next false
        end
        next false unless method.owner == owner

        text = changed_source(owner, name) || Source.method_source(method)
        text && text.include?(word) && Source.mentions_variable?(text, word)
      end
      names.sort.first(MAX_LISTED).map(&:to_s)
    end

    def changed_source(owner, name)
      target, side = Reflection.owner_target(owner)
      target && RubyTalk.changes&.find_method(target, side, name.to_s)&.source
    end

    # --- constants ------------------------------------------------------------

    def explain_constant(word, klass)
      mod = lookup_from(word, klass)
      return "#{word} looks like a constant, but nothing by that name is defined here (it may need a require)." unless mod
      return "#{word} is a constant: #{brief(mod)}" unless mod.is_a?(Module)

      describe_module(mod)
    end

    # Constants are found from the class in view first (nested names), then at the top level.
    def lookup_from(word, klass)
      if klass
        begin
          return klass.const_get(word)
        rescue NameError
          nil
        end
      end
      Object.const_get(word)
    rescue NameError, LoadError
      nil
    end

    def describe_module(mod)
      name = Reflection.name_of(mod) || mod.inspect
      kind = mod.is_a?(Class) ? 'class' : 'module'
      origin = RubyTalk.changes&.user_defined?(name) ? 'created in RubyTalk' : 'built in or loaded from a library'
      lines = ["#{name} is a #{kind} (#{origin})."]
      lines << "Superclass: #{Reflection.name_of(mod.superclass)}." if mod.is_a?(Class) && mod.superclass
      lines << "Includes: #{(mod.included_modules - Object.included_modules).filter_map { |m| Reflection.name_of(m) }.join(', ')}." if (mod.included_modules - Object.included_modules).any?
      lines << "#{mod.public_instance_methods(false).size} instance methods, #{mod.singleton_methods(false).size} class methods of its own."
      file, line = Object.const_source_location(name) if Reflection.lookup(name)
      lines << "Defined at #{file}:#{line}." if file && line && File.file?(file)
      comment = Source.split_comment(Reflection.class_definition(mod)).first.lines.map { |l| l.sub(/\A#\s?/, '').strip }.reject(&:empty?).first
      lines << "Comment: #{comment}" if comment
      lines.join("\n")
    end

    # --- selectors ------------------------------------------------------------

    def explain_selector(word, klass, side)
      lines = []
      method = klass && Reflection.method_object(klass, side, word)
      lines << describe_method(method, klass, side, word) if method
      implementors = Search.implementors(word)
      if implementors.empty?
        lines << "#{word}: no class implements a method with this name." unless method
      else
        shown = implementors.first(MAX_LISTED).map(&:label).join(', ')
        more = implementors.size > MAX_LISTED ? ", and #{implementors.size - MAX_LISTED} more" : ''
        lines << "#{word} is a message selector. Implemented by #{implementors.size} #{implementors.size == 1 ? 'class' : 'classes'}: #{shown}#{more}."
        lines << '(Edit > Implementors of it lists them all.)' if implementors.size > MAX_LISTED
      end
      lines.join("\n")
    end

    def describe_method(method, klass, side, word)
      visibility = visibility_of(method)
      who = "#{Reflection.name_of(klass)}#{side == :class ? '.' : '#'}#{word}"
      text = "#{who} resolves to #{Reflection.owner_label(method.owner)}##{word}: #{visibility}, arity #{method.arity}"
      file, line = method.source_location
      text += file ? ", defined at #{file}:#{line}." : ', implemented in C.'
      text
    end

    def visibility_of(method)
      owner = method.owner
      name = method.name
      if owner.private_method_defined?(name, false) then 'private'
      elsif owner.protected_method_defined?(name, false) then 'protected'
      else 'public'
      end
    end
  end
end
