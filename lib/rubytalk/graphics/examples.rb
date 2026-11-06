# frozen_string_literal: true

# Two small programs in the Model-View-Controller style, to read and to copy from. Open them from a
# Workspace:
#
#   GraphicsExamples::Counter.open
#   GraphicsExamples::Sketch.open
#   GraphicsExamples::Notes.open
module GraphicsExamples
  # A model with one number, a StringView that shows it, and three buttons that change it.
  class Counter < Model
    attr_reader :count

    def initialize
      super
      @count = 0
    end

    def increment
      @count += 1
      changed(:count)
    end

    def decrement
      @count -= 1
      changed(:count)
    end

    def reset
      @count = 0
      changed(:count)
    end

    def self.open
      model = new
      window = StandardSystemView.new('Counter', model, Point.new(240, 100))
      window.add_subview(StringView.new(model, Rectangle.from(10, 10, 220, 24), scale: 2) { |counter| "Count: #{counter.count}" })
      window.add_subview(ButtonView.new('-', Rectangle.from(10, 60, 60, 28)) { model.decrement })
      window.add_subview(ButtonView.new('Reset', Rectangle.from(90, 60, 60, 28)) { model.reset })
      window.add_subview(ButtonView.new('+', Rectangle.from(170, 60, 60, 28)) { model.increment })
      window.open
    end
  end

  # A drawing board. The model owns a Form; the view shows it; the controller turns mouse drags into lines.
  # Red button draws, yellow erases, blue clears. Keys: 1-9 pen width; r g b k y o colours; c clears.
  class Sketch < Model
    COLOURS = { 'r' => :red, 'g' => :green, 'b' => :blue, 'k' => :black, 'y' => :yellow, 'o' => :orange }.freeze

    attr_reader :form, :color, :width

    def initialize(width = 320, height = 240)
      super()
      @form = Form.new(width, height)
      @color = Color.black
      @width = 2
    end

    def line(from, to, color = @color, width = @width)
      pen = Pen.new(@form, color: color)
      pen.width = width
      pen.draw_line(from, to)
      changed(:picture)
    end

    def clear
      @form.clear
      changed(:picture)
    end

    def color=(color)
      @color = Color.coerce(color)
      changed(:color)
    end

    def width=(pixels)
      @width = [pixels.to_i, 1].max
      changed(:width)
    end

    def self.open(width = 320, height = 240)
      model = new(width, height)
      window = StandardSystemView.new('Sketch', model, Point.new(width, height))
      window.add_subview(SketchView.new(model, window.local_bounds))
      window.open
    end
  end

  class SketchView < View
    def default_controller_class
      SketchController
    end

    def display_view(form)
      form.copy_from(model.form)
    end
  end

  class SketchController < Controller
    ERASER_WIDTH = 10

    def mouse_down(point, button)
      case button
      when :blue then model.clear
      else
        @last = point
        stroke(point, point, button)
      end
    end

    def mouse_move(point)
      return unless @last

      stroke(@last, point, @button)
      @last = point
    end

    def mouse_up(_point, _button)
      @last = nil
    end

    def key_pressed(char, _keysym = nil)
      if char == 'c'
        model.clear
      elsif (1..9).cover?(char.to_i) && char.match?(/\A\d\z/)
        model.width = char.to_i
      elsif Sketch::COLOURS.key?(char)
        model.color = Sketch::COLOURS.fetch(char)
      end
    end

    private

    def stroke(from, to, button)
      @button = button
      if button == :yellow
        model.line(from, to, Color.white, ERASER_WIDTH)
      else
        model.line(from, to)
      end
    end
  end

  # A notebook: a scrolling list of notes (titled by their first line), a text editor for the selected note,
  # a New note button, and a yellow-button menu on the list. It shows a model feeding three kinds of view:
  # the list and the editor both depend on the model and update each other through it.
  class Notes < Model
    attr_reader :notes, :selected

    def initialize
      super
      @notes = [+"Welcome to Notes\nClick a note on the left, then type here.\nThe yellow button on the list has a menu."]
      @selected = 0
    end

    def titles
      @notes.map do |note|
        title = note.lines.first.to_s.strip
        title.empty? ? '(empty)' : title
      end
    end

    # The text of the selected note: what the editor reads and writes.
    def selected_text
      @notes[@selected].to_s
    end

    def selected_text=(text)
      @notes[@selected] = text
      changed(:titles)
    end

    def select(index)
      return unless index.between?(0, @notes.size - 1)

      @selected = index
      changed(:selected_text)
    end

    def add_note
      @notes << +''
      @selected = @notes.size - 1
      changed(:titles)
      changed(:selected_text)
    end

    def duplicate_selected
      @notes.insert(@selected + 1, selected_text.dup)
      @selected += 1
      changed(:titles)
      changed(:selected_text)
    end

    # There is always at least one note.
    def delete_selected
      return if @notes.size <= 1

      @notes.delete_at(@selected)
      @selected = [@selected, @notes.size - 1].min
      changed(:titles)
      changed(:selected_text)
    end

    def self.open
      model = new
      window = StandardSystemView.new('Notes', model, Point.new(480, 280))
      list = window.add_subview(NotesListView.new(model.titles, Rectangle.from(0, 0, 150, 250)))
      list.model = model
      list.selection = model.selected
      list.on_select = ->(index, _title) { model.select(index) }
      list.controller.yellow_button_menu = PopUpMenu.new([['New note', -> { model.add_note }],
                                                          ['Duplicate', -> { model.duplicate_selected }], '-',
                                                          ['Delete', -> { model.delete_selected }]])
      window.add_subview(ButtonView.new('New note', Rectangle.from(0, 252, 150, 26)) { model.add_note })
      window.add_subview(TextView.new(model, Rectangle.from(150, 0, 330, 280), aspect: :selected_text))
      window.open
    end
  end

  # The list of note titles, redrawn from the model whenever it changes.
  class NotesListView < ListView
    def update(_aspect = nil, _with = nil)
      @items = model.titles
      @selection = model.selected
      ensure_visible(@selection)
      invalidate
    end
  end
end
