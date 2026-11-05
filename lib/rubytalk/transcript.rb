# frozen_string_literal: true

module RubyTalk
  # The Transcript: a Smalltalk-style global text stream.
  #
  # It keeps a bounded in-memory buffer and notifies listeners (the Transcript
  # window) as text arrives. It speaks both the Smalltalk protocol (show, cr,
  # tab, space, display ...) and enough of Ruby's IO protocol (write, puts,
  # print, printf, <<) that it can stand in for $stdout while code is being
  # evaluated, so `puts` in a Workspace lands in the Transcript.
  class TranscriptStream
    MAX_BUFFER = 1_000_000

    attr_reader :buffer

    def initialize
      @buffer = +''
      @listeners = []
    end

    # Listeners receive either a String chunk or the Symbol :clear.
    def add_listener(&block)
      @listeners << block
      block
    end

    def remove_listener(listener)
      @listeners.delete(listener)
    end

    # --- Smalltalk protocol -------------------------------------------------

    # Transcript.show 'text'   (Smalltalk: Transcript show: 'text')
    def show(object = '')
      emit(object.to_s)
      self
    end
    alias nextPutAll show

    def show_cr(object = '')
      show(object)
      cr
    end
    alias showCr show_cr

    def display(object)
      show(object.to_s)
    end

    def display_nl(object)
      display(object)
      cr
    end
    alias displayNl display_nl

    # Smalltalk's `Transcript print: anObject` (shows the printString).
    # Named print_string because Ruby's IO#print must keep its own meaning.
    def print_string(object)
      show(object.inspect)
    end

    def cr
      emit("\n")
      self
    end
    alias nl cr
    alias newLine cr

    def tab(count = 1)
      emit("\t" * count)
      self
    end

    def space(count = 1)
      emit(' ' * count)
      self
    end

    def clear
      @buffer.clear
      @listeners.each { |listener| listener.call(:clear) }
      self
    end

    def flush
      self
    end
    alias endEntry flush

    # --- IO protocol (so it can replace $stdout / $stderr) ------------------

    def write(*objects)
      objects.sum do |object|
        text = object.to_s
        emit(text)
        text.bytesize
      end
    end

    def <<(object)
      emit(object.to_s)
      self
    end

    def print(*objects)
      objects.each { |object| emit(object.to_s) }
      nil
    end

    def puts(*objects)
      if objects.empty?
        emit("\n")
      else
        objects.flatten.each do |object|
          text = object.to_s
          emit(text)
          emit("\n") unless text.end_with?("\n")
        end
      end
      nil
    end

    def printf(format_string, *arguments)
      emit(format(format_string, *arguments))
      nil
    end

    def putc(char)
      emit(char.is_a?(Integer) ? char.chr : char.to_s[0].to_s)
      char
    end

    def sync
      true
    end

    def sync=(value)
      value
    end

    def tty?
      false
    end
    alias isatty tty?

    def fsync
      0
    end

    def fileno
      nil
    end

    private

    def emit(text)
      return if text.empty?

      @buffer << text
      overflow = @buffer.size - MAX_BUFFER
      @buffer.slice!(0, overflow) if overflow.positive?
      @listeners.each { |listener| listener.call(text) }
    end
  end
end
