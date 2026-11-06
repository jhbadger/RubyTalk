# frozen_string_literal: true

# The M of MVC: anything a program is about (a counter, a drawing, a document). A Model keeps a list of
# dependents (usually Views) and tells them when it changes; Views redraw themselves in response.
#
#   class Counter < Model
#     def increment
#       @count = count + 1
#       changed(:count)          # every dependent view receives update(:count, nil)
#     end
#   end
class Model
  include Dependents
end
