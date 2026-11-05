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
  # Real Tk is single-threaded (Cocoa insists on the main thread). RubyTalk runs do its
  # on a worker thread and must hand every window operation to the main thread.
  def self.main_thread!(what)
    return if Thread.current == Thread.main

    raise "fake Tk: #{what} used off the main thread (RubyTalk must hand it to GUI.on_main)"
  end

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
  TK_VERSION = '0.0-fake'

  class << self
    # Understands just the raw calls RubyTalk makes: message boxes, winfo,
    # `event generate`, listbox `size`, and the menu queries/invokes used by the
    # self-test. Everything else is accepted and ignored.
    # Hooks for tests: update_hook runs on every `update` (as if events were being
    # handled); last_title is the most recent `wm title`.
    attr_accessor :update_hook, :last_title

    def update_count
      @update_count ||= 0
    end

    def tk_call(*args)
      FakeStrict.main_thread!('tk_call')
      FakeStrict.check(args)
      if args.first == 'update'
        @update_count = update_count + 1
        TkTimer.run_pending
        update_hook&.call
      end
      self.last_title = args[3] if args[0] == 'wm' && args[1] == 'title'
      first = args.first.to_s
      return (message_answer || 'yes') if first == 'tk_messageBox'
      return winfo_call(args) if first == 'winfo'
      return wm_call(args) if first == 'wm' && args[1] == 'geometry'
      return generate_event(args) if first == 'event' && args[1] == 'generate'
      return image_call(args) if first == 'image'
      return chooser_call(args) if first == 'tk_chooseDirectory'
      return dialog_call(args) if %w[tk_getSaveFile tk_getOpenFile].include?(first)
      return define_proc(args) if first == 'proc'
      return call_proc(first) if @procs&.key?(first)

      widget = FakeWidget.find(first)
      return widget_call(widget, args[1..]) if widget

      ''
    end

    # The file dialogs (tk_getSaveFile / tk_getOpenFile): tests set Tk.dialog_answer ('' is Cancel) and read
    # Tk.dialog_requests.
    attr_accessor :dialog_answer

    def dialog_requests
      @dialog_requests ||= []
    end

    def dialog_call(args)
      dialog_requests << args
      dialog_answer.to_s
    end

    # The folder chooser: tests set Tk.chooser_answer ('' means Cancel) and read
    # Tk.chooser_requests to see the options RubyTalk passed.
    attr_accessor :chooser_answer, :message_answer, :rgb_answer

    def chooser_requests
      @chooser_requests ||= []
    end

    def chooser_call(args)
      chooser_requests << args[1..]
      chooser_answer.to_s
    end

    # Window geometry: `wm geometry path spec` sets it, `wm geometry path` returns "WxH+X+Y" (a window
    # that was only given a position has a 100x100 size, as if the widgets decided it).
    def wm_call(args)
      @geometries ||= {}
      if args.size >= 4
        @geometries[args[2]] = args[3]
        ''
      else
        spec = @geometries.fetch(args[2], '+0+0')
        spec.start_with?('+', '-') ? "100x100#{spec}" : spec
      end
    end

    attr_writer :screen_width, :screen_height

    def screen_width
      @screen_width ||= 1440
    end

    def screen_height
      @screen_height ||= 900
    end

    def winfo_call(args)
      case args[1]
      when 'rgb' then rgb_answer || '65535 65535 65535'
      when 'screenwidth' then screen_width.to_s
      when 'screenheight' then screen_height.to_s
      when 'exists' then FakeWidget.find(args[2])&.destroyed? == false ? '1' : '0'
      else '0'
      end
    end

    # Just enough Tcl to model `proc ::tk::mac::Quit {} {eval [wm protocol . WM_DELETE_WINDOW]}`.
    def define_proc(args)
      (@procs ||= {})[args[1]] = args[3]
      ''
    end

    def call_proc(name)
      body = @procs.fetch(name)
      raise "fake Tk: unsupported proc body #{body.inspect}" unless body.include?('wm protocol . WM_DELETE_WINDOW')

      root.protocols['WM_DELETE_WINDOW']&.call
      ''
    end

    # `image create photo -data ...`, `image type`, `image width` (the window icon).
    def image_call(args)
      case args[1]
      when 'create' then (@images ||= []).push(args.last(3)).then { "image#{@images.size}" }
      when 'type' then 'photo'
      when 'width' then '128'
      else ''
      end
    end

    def generate_event(args)
      widget = FakeWidget.find(args[2]) or raise "fake Tk: no widget #{args[2]}"
      pattern = args[3].to_s.delete('<>')
      widget.fire(pattern) if widget.bindings.key?(pattern)
      ''
    end

    def widget_call(widget, rest)
      case rest.first
      when 'size' then widget.items.size.to_s
      when 'insert' then widget.insert(rest[1], rest[2]) # text insert index chars
      when 'count' then widget.offset_for(rest.last).to_s # text -chars first last
      when 'index' then widget.index(rest[1]) # text index
      when 'mark'
        widget.insert_offset = widget.offset_for(rest[3]) if rest[1] == 'set' && rest[2] == 'insert'
        ''
      when 'get' then widget.items[rest[1].to_i].to_s # listbox row text
      when 'cget'
        value = widget.options[rest[1].delete_prefix('-').to_sym]
        value.respond_to?(:path) ? value.path : value.to_s
      when 'tag' then widget.tag_command(rest[1..]).to_s
      when 'entrycget' then widget.entries.find { |_, o| o[:label] == rest[1] }[1][:menu].path
      when 'invoke' then widget.invoke(rest[1]).to_s
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
  @@registry = {}
  attr_reader :path, :options, :bindings, :children

  def self.find(path)
    @@registry[path]
  end

  def initialize(parent = nil, options = nil, &_block)
    FakeStrict.main_thread!("creating #{self.class}")
    @@count += 1
    @path = ".w#{@@count}"
    @@registry[@path] = self
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

  # `window.protocol('WM_DELETE_WINDOW') { ... }` registers a handler.
  def protocol(name, *_rest, &block)
    protocols[name] = block
    self
  end

  def protocols
    @protocols ||= {}
  end

  def destroyed?
    !!@destroyed
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

# Ruby/Tk's timer: TkTimer.new(interval, loop_count, *procs). Fired by `update` (one-shot
# timers once, repeating timers every time) or explicitly with #fire in a test.
class TkTimer
  @all = []

  class << self
    attr_reader :all

    def run_pending
      all.dup.each { |timer| timer.fire if timer.started? }
      all.reject! { |timer| timer.loop_count == 1 && !timer.started? }
    end
  end

  attr_reader :loop_count

  def initialize(interval = nil, loop_count = 1, *procs, &block)
    @loop_count = loop_count
    @procs = procs
    @procs << block if block
    @started = false
    self.class.all << self
  end

  def start(*)
    @started = true
    self
  end

  def started?
    @started
  end

  def fire
    @started = false if @loop_count == 1
    @procs.each(&:call)
  end
end

class TkRoot < FakeWidget
  def initialize(*)
    super
    Tk.instance_variable_set(:@root, self) # like the real Tk.root: the most recent root window
  end
end
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
  attr_accessor :insert_offset

  def initialize(*)
    super
    @content = +''
    @selection = nil
  end

  # Test helper: pretend the user selected +string+ (it must occur in the text).
  def select_text(string)
    raise 'text not found' unless @content.include?(string)

    @selection = string
    first = @content.index(string)
    @selection_range = [first, first + string.size]
  end

  def get(first, last = nil)
    return @content.dup if [first, last] == ['1.0', 'end-1c']

    start = offset_for(first)
    @content[start...(last ? offset_for(last) : start + 1)].to_s
  end

  # Like real Tk, asking for sel.first/sel.last with nothing selected is an error.
  def selection_range!
    @selection_range || raise('text doesn\'t contain any characters tagged with "sel"')
  end

  # Character offset for the index forms RubyTalk uses ("insert" is taken to be on line 1).
  def offset_for(index)
    case index.to_s
    when 'end', 'end-1c', 'end - 1 chars' then @content.size # real Tk keeps a hidden final newline, so end-1c is the true end
    when 'insert' then @insert_offset || 0
    when 'sel.first' then selection_range!.first
    when 'sel.last' then selection_range!.last
    when 'insert linestart' then line_start((@insert_offset || 0))
    when 'insert lineend' then line_end((@insert_offset || 0))
    when /\A(\d+)\.(\d+)\z/ then @content.lines[0...(Regexp.last_match(1).to_i - 1)].sum(&:size) + Regexp.last_match(2).to_i
    when /\A(\d+)\.end\z/ then @content.lines[0...(Regexp.last_match(1).to_i - 1)].sum(&:size) + @content.lines[Regexp.last_match(1).to_i - 1].to_s.chomp.size
    when /\A(.+?)\s*\+\s*(\d+)\s*(?:c|chars)\z/ then [offset_for(Regexp.last_match(1)) + Regexp.last_match(2).to_i, @content.size].min
    when /\A(.+?)\s*-\s*(\d+)\s*(?:c|chars)\z/ then [offset_for(Regexp.last_match(1)) - Regexp.last_match(2).to_i, 0].max
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
    FakeStrict.main_thread!('text insert')
    FakeStrict.check(string)
    offset = offset_for(index)
    @content.insert(offset, string)
    # Like a real text widget, the cursor mark moves along when text goes in at or before it.
    @insert_offset = (@insert_offset || 0) + string.size if @insert_offset && offset <= @insert_offset
    self
  end

  def line_start(offset)
    offset.zero? ? 0 : (@content.rindex("\n", offset - 1) || -1) + 1
  end

  def line_end(offset)
    @content.index("\n", offset) || @content.size
  end

  def delete(first = '1.0', last = nil)
    if first == '1.0' && last == 'end'
      @content = +''
      @selection = nil
      @selection_range = nil
      @insert_offset = 0 if @insert_offset
    else
      from = offset_for(first)
      to = last ? offset_for(last) : from + 1
      @content.slice!(from...to)
      # Marks inside or after the deleted text move back with it.
      @insert_offset = [@insert_offset - (to - from), from].max if @insert_offset && @insert_offset > from
    end
    self
  end

  # `.text tag configure|add|remove|names ...` as sent by Tk.tk_call (the highlighter's tags).
  def tag_options
    @tag_options ||= {}
  end

  def tag_store
    @tag_store ||= Hash.new { |hash, key| hash[key] = [] }
  end

  def tag_command(args)
    case args[0]
    when 'configure' then tag_options[args[1]] = Hash[*args[2..]]
    when 'remove' then tag_store.delete(args[1])
    when 'add'
      args[2..].each_slice(2) { |first, last| tag_store[args[1]] << [offset_for(first), offset_for(last)] }
    when 'names'
      offset = offset_for(args[1])
      tag_store.select { |_, ranges| ranges.any? { |first, last| first <= offset && offset < last } }.keys.join(' ')
    end
  end

  def tag_add(tag, first = nil, last = nil, *)
    if tag == 'sel'
      @selection_range = [offset_for(first), offset_for(last)]
      @selection = @content[offset_for(first)...offset_for(last)]
    end
    self
  end

  def tag_remove(tag, *)
    if tag == 'sel'
      @selection = nil
      @selection_range = nil
    end
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
