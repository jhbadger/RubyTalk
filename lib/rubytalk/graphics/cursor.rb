# frozen_string_literal: true

# A mouse cursor shape (Smalltalk-80's Cursor). RubyTalk windows use Tk's named cursors; the optional
# +form+ and +hot_spot+ describe the bitmap for programs that draw their own.
#
#   Cursor.crosshair      Cursor.wait      Cursor.normal
class Cursor
  attr_reader :tk_name, :form, :hot_spot

  NAMES = { normal: 'arrow', crosshair: 'crosshair', wait: 'watch', origin: 'top_left_arrow', text: 'xterm',
            hand: 'hand2', move: 'fleur' }.freeze

  class << self
    NAMES.each do |name, tk_name|
      define_method(name) { new(tk_name) }
    end
  end

  def initialize(tk_name, form = nil, hot_spot = Point.new(0, 0))
    @tk_name = tk_name
    @form = form
    @hot_spot = hot_spot
    freeze
  end

  def ==(other)
    other.is_a?(Cursor) && tk_name == other.tk_name && form == other.form && hot_spot == other.hot_spot
  end

  def to_s
    "a Cursor(#{@tk_name})"
  end
  alias inspect to_s
end
