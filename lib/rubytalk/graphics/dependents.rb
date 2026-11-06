# frozen_string_literal: true

# Smalltalk-80's dependency mechanism (Object>>addDependent:, changed:, update:). A Model, a Form,
# or anything that includes this keeps a list of dependents (usually Views) and tells them when it
# changes:
#
#   model.add_dependent(view)
#   model.changed(:count)            # every dependent receives view.update(:count, nil)
#   model.changed(:item, with: 3)    # ... update(:item, 3)
module Dependents
  def dependents
    (@dependents ||= []).dup
  end

  def add_dependent(dependent)
    list = (@dependents ||= [])
    list << dependent unless list.any? { |existing| existing.equal?(dependent) }
    dependent
  end

  def remove_dependent(dependent)
    (@dependents ||= []).delete_if { |existing| existing.equal?(dependent) }
    dependent
  end

  # Tell every dependent that +aspect+ of the receiver changed.
  def changed(aspect = nil, with: nil)
    dependents.each { |dependent| dependent.update(aspect, with) }
    self
  end

  # Forget every dependent.
  def release_dependents
    @dependents = []
    self
  end
end
