# frozen_string_literal: true

# Smalltalk-80's graphics classes (Point, Rectangle, Form, BitBlt, Pen, ...) and, in the same
# directory, its Model-View-Controller interface framework. They are defined at the top level, as in
# Smalltalk, so a Workspace can use them directly, and they appear in the browser under "Graphics-..."
# and "Interface-..." like any other class. This file loads them in dependency order.
require_relative 'graphics/dependents'
require_relative 'graphics/color'
require_relative 'graphics/point'
require_relative 'graphics/rectangle'
require_relative 'graphics/bitblt'
require_relative 'graphics/form'
require_relative 'graphics/font'
require_relative 'graphics/pen'
require_relative 'graphics/paths'
require_relative 'graphics/cursor'

# The Model-View-Controller framework.
require_relative 'graphics/model'
require_relative 'graphics/sensor'
require_relative 'graphics/scrollable'
require_relative 'graphics/view'
require_relative 'graphics/controller'
require_relative 'graphics/control_manager'
require_relative 'graphics/examples'
