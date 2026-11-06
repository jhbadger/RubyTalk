# frozen_string_literal: true

# The V of MVC: something on screen that shows a model and owns the area it draws in. Views nest: a
# window (StandardSystemView) holds subviews, which hold more. Each view draws into its OWN Form with
# the origin at its top-left, so its code never needs to know where it sits; the framework copies the
# result into the parent at `bounds`, clipped to the view. A view redraws when its model calls `changed`
# (the dependency mechanism calls #update).
#
#   class Meter < View
#     def display_view(form)
#       form.fill(Rectangle.from(0, 0, model.level, form.height), Color.green)
#     end
#   end
class View
  attr_reader :model, :superview, :subviews
  # bounds is this view's rectangle in its superview's coordinates.
  attr_accessor :bounds, :background, :foreground, :border_width, :cursor, :invalidated

  def initialize(model = nil, bounds = Rectangle.from(0, 0, 100, 100))
    @subviews = []
    @superview = nil
    @bounds = bounds
    @background = Color.white
    @foreground = Color.black
    @border_width = 0
    @cursor = nil
    @invalidated = true
    @controller = nil
    @model = nil
    self.model = model
  end

  def model=(new_model)
    @model.remove_dependent(self) if @model.respond_to?(:remove_dependent)
    @model = new_model
    new_model.add_dependent(self) if new_model.respond_to?(:add_dependent)
    invalidate
  end

  # The controller that handles the mouse and keyboard over this view (made on first use).
  def controller
    @controller ||= default_controller_class.new(self)
  end

  def controller=(controller)
    @controller = controller
    controller.view = self
  end

  def default_controller_class
    Controller
  end

  # --- structure -------------------------------------------------------------

  # Add +view+ on top of the others, at +bounds+ (in this view's coordinates).
  def add_subview(view, bounds = nil)
    view.bounds = bounds if bounds
    view.instance_variable_set(:@superview, self)
    @subviews << view
    invalidate
    view
  end

  def remove_subview(view)
    @subviews.delete(view)
    view.instance_variable_set(:@superview, nil)
    invalidate
    view
  end

  def top_view
    @superview ? @superview.top_view : self
  end

  def width
    bounds.width
  end

  def height
    bounds.height
  end

  def extent
    bounds.extent
  end

  # The view's own area, with its origin at 0@0.
  def local_bounds
    Rectangle.origin_extent(Point.new(0, 0), bounds.extent)
  end

  # Where this view's top-left is within its window (the top view).
  def origin_in_top
    @superview ? @superview.origin_in_top + bounds.origin : Point.new(0, 0)
  end

  # A point in window coordinates, in this view's own coordinates.
  def to_local(point_in_top)
    point_in_top - origin_in_top
  end

  def contains_point?(local_point)
    local_bounds.contains?(local_point)
  end

  # The deepest view at +point+ (given in this view's coordinates) and the point in that view's own
  # coordinates: [view, point]. Later (higher) subviews win.
  def view_at(point)
    @subviews.reverse_each do |subview|
      return subview.view_at(point - subview.bounds.origin) if subview.bounds.contains?(point)
    end
    [self, point]
  end

  # --- drawing ---------------------------------------------------------------

  # Ask for a redraw (done after the current event, or by the window's refresh timer).
  def invalidate
    top = top_view
    top.invalidated = true
    self
  end

  # The dependency mechanism calls this when the model changes; the default is to redraw.
  def update(_aspect = nil, _with = nil)
    invalidate
  end

  # Draw this view (and everything inside it) into a new Form of its own size.
  def render
    form = Form.new([bounds.width, 0].max, [bounds.height, 0].max, background)
    display_view(form)
    @subviews.each { |subview| subview.display_on(form) }
    form.border(nil, border_width, foreground) if border_width.positive?
    form
  end

  # Draw this view into +target+ at its position in the parent.
  def display_on(target)
    target.copy_from(render, to: bounds.origin)
  end

  # Override: draw the view's own content into +form+ (origin at its top-left; the background is done).
  def display_view(form); end

  # Stop depending on the model, recursively. The window manager calls this when a window closes.
  def release
    @model.remove_dependent(self) if @model.respond_to?(:remove_dependent)
    @subviews.each(&:release)
  end

  def to_s
    "a #{self.class.name}(#{bounds})"
  end
  alias inspect to_s
end

# A top-level window: the root of a view tree, shown in its own Tk window. Its size is the extent given.
#
#   window = StandardSystemView.new('Counter', model, Point.new(240, 110))
#   window.add_subview(StringView.new(model, Rectangle.from(10, 10, 220, 24)) { |m| "Count: #{m.count}" })
#   window.open
class StandardSystemView < View
  attr_accessor :label, :display_hook, :close_hook
  # The most recent picture of the window (a Form), after it is drawn.
  attr_reader :form

  def initialize(label = 'Untitled', model = nil, extent = Point.new(300, 200))
    super(model, Rectangle.origin_extent(Point.new(0, 0), extent))
    @label = label
    @form = nil
    @display_hook = nil
    @close_hook = nil
  end

  def default_controller_class
    StandardSystemController
  end

  # Show the window. Returns the view.
  def open(manager = ControlManager.instance)
    manager.open(self)
    self
  end

  def close(manager = ControlManager.instance)
    manager.close(self)
  end

  def open?(manager = ControlManager.instance)
    manager.windows.include?(self)
  end

  # Draw the window into its Form now and give it to the display hook.
  def redisplay
    @invalidated = false
    @form = render
    @display_hook&.call(@form)
    @form
  end
end

# Shows a Form (the model), with its top-left at the view's top-left.
class FormView < View
  def initialize(form, bounds = nil)
    super(form, bounds || form.bounds)
  end

  def display_view(form)
    form.copy_from(model) if model
  end
end

# A line (or several) of text: a fixed string, or computed from the model each time it is drawn.
#
#   StringView.new(model, bounds) { |m| "Count: #{m.count}" }
#   StringView.new(nil, bounds, text: 'Hello', scale: 2)
class StringView < View
  attr_accessor :text, :scale

  def initialize(model = nil, bounds = Rectangle.from(0, 0, 100, 20), text: nil, scale: 1, &text_block)
    super(model, bounds)
    @text = text
    @scale = scale
    @text_block = text_block
  end

  def string
    @text_block ? @text_block.call(model).to_s : @text.to_s
  end

  def display_view(form)
    form.draw_string(string, Point.new(4, 3), color: foreground, scale: scale)
  end
end

# A push button: shows a label, looks pressed while the red button is down on it, and calls its action
# when the button is released inside it.
#
#   ButtonView.new('Reset', Rectangle.from(10, 60, 80, 24)) { model.reset }
class ButtonView < View
  attr_accessor :label, :action, :scale
  attr_reader :pressed

  def initialize(label, bounds = Rectangle.from(0, 0, 80, 24), &action)
    super(nil, bounds)
    @label = label
    @action = action
    @scale = 1
    @pressed = false
    @border_width = 1
  end

  def default_controller_class
    ButtonController
  end

  def pressed=(flag)
    @pressed = flag
    invalidate
  end

  # Run the action (the controller calls this when the button is released inside).
  def activate
    @action&.call
  end

  def display_view(form)
    size = Font.default.extent_of(@label, @scale)
    form.draw_string(@label, (local_bounds.extent - size).div(2), color: foreground, scale: @scale)
    form.reverse if @pressed
  end
end

# A scrolling-free list of strings with one selected row. Clicking selects; the optional block (or
# #on_select) is called with the index and the item.
#
#   ListView.new(%w[red green blue], Rectangle.from(10, 10, 120, 100)) { |index, item| ... }
class ListView < View
  ROW_HEIGHT = 12

  attr_reader :items, :selection
  attr_accessor :on_select

  def initialize(items = [], bounds = Rectangle.from(0, 0, 120, 100), &on_select)
    super(nil, bounds)
    @items = items.map(&:to_s)
    @selection = nil
    @on_select = on_select
    @border_width = 1
  end

  def default_controller_class
    ListController
  end

  def items=(list)
    @items = list.map(&:to_s)
    @selection = nil
    invalidate
  end

  def selection=(index)
    @selection = index && index.between?(0, @items.size - 1) ? index : nil
    invalidate
  end

  def selected_item
    @selection && @items[@selection]
  end

  # Select the row under +point+ (view coordinates) and tell the block.
  def select_at(point)
    index = (point.y - 2).div(ROW_HEIGHT)
    return unless index.between?(0, @items.size - 1)

    self.selection = index
    @on_select&.call(index, @items[index])
  end

  def display_view(form)
    @items.each_with_index do |item, index|
      top = 2 + (index * ROW_HEIGHT)
      break if top > height

      if index == @selection
        form.fill(Rectangle.from(1, top - 1, [width - 2, 0].max, ROW_HEIGHT), foreground)
        form.draw_string(item, Point.new(4, top), color: background)
      else
        form.draw_string(item, Point.new(4, top), color: foreground)
      end
    end
  end
end
