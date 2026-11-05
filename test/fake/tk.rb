# frozen_string_literal: true

# A stand-in for the 'tk' gem, used ONLY by test/test_gui_smoke.rb so the GUI code
# can be exercised on a machine with no display. It records state (text contents,
# list items, menu entries, bindings) and accepts any other call silently.
# It does not prove the real Tk API calls are right; it catches typos, nil
# references and logic errors in RubyTalk's own GUI code.

class TkCallbackBreak < StandardError; end

# The real tk gem calls String#force_encoding on strings it is given, so a frozen
# string (e.g. from a `frozen_string_literal: true` file, or Module#name) raises
# FrozenError. The fake reproduces that so such bugs fail the tests.
module FakeStrict
  def self.check(*values)
    values.each do |v|
      case v
      when String then raise FrozenError, "can't modify frozen String: #{v.inspect}" if v.frozen?
      when Array then check(*v)
      when Hash then check(*v.values)
      end
    end
  end
end

module Tk
  class << self
    def tk_call(*args)
      FakeStrict.check(args)
      case args.first
      when 'tk_messageBox' then 'yes'
      when 'winfo' then '0'
      else ''
      end
    end

    def callback_break
      raise TkCallbackBreak, 'break'
    end

    def mainloop; end

    def root
      @root ||= TkRoot.new
    end
  end
end

class TkVariable
  attr_reader :value

  def initialize(value = '')
    FakeStrict.check(value)
    @value = value
  end

  def value=(new_value)
    FakeStrict.check(new_value)
    @value = new_value
  end
end

class FakeWidget
  @@count = 0
  attr_reader :path, :options, :bindings, :children

  def initialize(parent = nil, options = nil, &_block)
    @@count += 1
    @path = ".w#{@@count}"
    @parent = parent
    FakeStrict.check(options) if options.is_a?(Hash)
    @options = options.is_a?(Hash) ? options.dup : {}
    @bindings = {}
    @children = []
    parent.children << self if parent.respond_to?(:children)
  end

  def bind(event, *_rest, &block)
    @bindings[event] = block
    self
  end

  # Simulate the user pressing a key / clicking: runs the binding like Tk would.
  def fire(event)
    block = @bindings.fetch(event)
    block.call
    :continue
  rescue TkCallbackBreak
    :break
  end

  def configure(options = nil, *_rest)
    FakeStrict.check(options) if options.is_a?(Hash)
    @options.merge!(options) if options.is_a?(Hash)
    self
  end

  def destroy
    @destroyed = true
  end

  def destroyed?
    @destroyed
  end

  def pack(*)
    self
  end

  def method_missing(_name, *_args)
    self
  end

  def respond_to_missing?(*)
    true
  end
end

class TkRoot < FakeWidget; end
class TkToplevel < FakeWidget; end
class TkFrame < FakeWidget; end
class TkLabel < FakeWidget; end
class TkButton < FakeWidget; end
class TkRadiobutton < FakeWidget; end
class TkCheckButton < FakeWidget; end
class TkEntry < FakeWidget; end
class TkScrollbar < FakeWidget; end

class TkMenu < FakeWidget
  attr_reader :entries

  def add(type, options = {})
    FakeStrict.check(type, options)
    (@entries ||= []) << [type, options]
    self
  end

  # Invoke a command entry by its label, as the user would.
  def invoke(label)
    entry = entries.find { |_, options| options[:label] == label } or raise "no menu entry #{label.inspect}"
    entry[1][:command].call
  end
end

class TkText < FakeWidget
  attr_reader :content

  def initialize(*)
    super
    @content = +''
    @selection = nil
  end

  # Test helper: pretend the user selected +string+ (it must occur in the text).
  def select_text(string)
    raise 'text not found' unless @content.include?(string)

    @selection = string
  end

  def get(first, last = nil)
    case [first, last]
    when ['1.0', 'end-1c'] then @content.dup
    when ['sel.first', 'sel.last'] then @selection || raise('text doesn\'t contain any characters tagged with "sel"')
    when ['insert linestart', 'insert lineend'] then @content.lines.first.to_s.chomp
    else @content.dup
    end
  end

  # Character offset for the index forms RubyTalk uses ("insert" is taken to be on line 1).
  def offset_for(index)
    case index.to_s
    when 'end' then @content.size
    when 'sel.first' then @content.index(@selection.to_s) || 0
    when 'sel.last' then (@content.index(@selection.to_s) || 0) + @selection.to_s.size
    when 'insert linestart' then 0
    when 'insert lineend' then @content.lines.first.to_s.chomp.size
    when /\A(\d+)\.(\d+)\z/ then @content.lines[0...(Regexp.last_match(1).to_i - 1)].sum(&:size) + Regexp.last_match(2).to_i
    when /\A(.+)\+(\d+)c\z/ then offset_for(Regexp.last_match(1)) + Regexp.last_match(2).to_i
    else raise "fake Tk: unsupported text index #{index.inspect}"
    end
  end

  def index(name)
    offset = offset_for(name)
    before = @content[0...offset]
    column = offset - (before.rindex("\n")&.+(1) || 0)
    "#{before.count("\n") + 1}.#{column}"
  end

  def insert(index, string, *_tags)
    FakeStrict.check(string)
    @content.insert(offset_for(index), string)
    self
  end

  def delete(*)
    @content = +''
    @selection = nil
    self
  end

  def tag_add(tag, *)
    self
  end

  def tag_remove(*)
    self
  end
end

class TkListbox < FakeWidget
  attr_reader :items

  def initialize(*)
    super
    @items = []
    @selected = nil
  end

  def insert(_index, item)
    FakeStrict.check(item)
    @items << item
    self
  end

  def delete(*)
    @items = []
    @selected = nil
    self
  end

  def selection_set(index, *)
    @selected = index
  end

  def selection_clear(*)
    @selected = nil
  end

  def curselection
    @selected ? [@selected] : []
  end

  # Simulate the user clicking row +index+ (selection changes, then mouse release).
  def click(index)
    @selected = index
    fire('ButtonRelease-1')
  end
end
