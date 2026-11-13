# frozen_string_literal: true

# Shared setup for the model-view-controller tests (test_mvc_*.rb). No display needed.

$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'minitest/autorun'
require 'zlib'
require 'rubytalk'
class MvcCase < Minitest::Test
  def setup
    Transcript.clear
    @manager = ControlManager.new
  end

  def pt(x, y)
    Point.new(x, y)
  end

  # A view that paints its whole area one colour, and records how it was drawn.
  class SolidView < View
    attr_reader :draws

    def initialize(color, bounds, model = nil)
      super(model, bounds)
      @color = color
      @draws = 0
    end

    def display_view(form)
      @draws += 1
      form.fill(nil, @color)
    end
  end

  # A controller that records everything it is sent.
  class Recorder < Controller
    attr_reader :log

    def initialize(view = nil)
      super
      @log = []
    end

    def mouse_down(point, button)
      @log << [:down, point, button]
    end

    def mouse_up(point, button)
      @log << [:up, point, button]
    end

    def mouse_move(point)
      @log << [:move, point]
    end

    def mouse_enter
      @log << :enter
      super
    end

    def mouse_leave
      @log << :leave
      super
    end

    def key_pressed(char, keysym = nil)
      @log << [:key, char, keysym]
    end

    def control_initialize
      @log << :initialize
    end

    def control_terminate
      @log << :terminate
    end

    def control_activity
      @log << :activity
    end
  end

  def window(extent = pt(100, 80), model = nil)
    StandardSystemView.new('Test', model, extent)
  end

  def with_recorder(view)
    recorder = Recorder.new(view)
    view.controller = recorder
    recorder
  end
end
