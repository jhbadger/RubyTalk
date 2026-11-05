# frozen_string_literal: true

module RubyTalk
  # What the debugger shows about an error, with no GUI so it can be tested headlessly:
  # the stack frames, the source around a frame, the variables of the frame that raised
  # (the only one whose binding Ruby lets us keep), and which method to open for editing.
  module Stack
    Frame = Struct.new(:path, :lineno, :label, :binding) do
      def to_s
        "#{path}:#{lineno} in #{label}"
      end
    end

    # Files used to label code evaluated from the windows (do its), as opposed to real files.
    EVAL_LABEL = /\A[a-z][a-z ]*\z/.freeze

    module_function

    # The error's frames, innermost first, without RubyTalk's own plumbing. +binding+ (where
    # it was raised) is attached to the frame it belongs to.
    def frames(error, binding = nil)
      list = locations(error).reject { |frame| internal?(frame.path) }
      attach_binding(list, binding)
      list
    end

    def locations(error)
      located = error.backtrace_locations
      return located.map { |l| Frame.new(l.path, l.lineno, l.label, nil) } if located

      (error.backtrace || []).filter_map do |line|
        match = line.match(/\A(.+?):(\d+):in [`'](.*)'\z/) or next
        Frame.new(match[1], match[2].to_i, match[3], nil)
      end
    end

    def internal?(path)
      path = path.to_s
      path.start_with?(RubyTalk::LIB_DIR) || path.include?('/gems/tk-')
    end

    def attach_binding(frames, binding)
      return unless binding

      path, line = binding.source_location
      target = frames.find { |frame| frame.path == path && frame.lineno == line } || frames.first
      target.binding = binding if target
    end

    # [["self", obj], ["x", 5], ...] for a frame that has a binding, else [].
    def variables(binding)
      return [] unless binding

      rows = [['self', binding.receiver]]
      binding.local_variables.each do |name|
        rows << [name.to_s, binding.local_variable_get(name)]
      rescue StandardError
        next
      end
      rows
    end

    # [text, current_line, first_line]: source to show for +frame+, the line (within that
    # text, 1-based) to mark, and the file line the text starts at. Big files show a window.
    def source_view(frame, doit_source = nil, changes = RubyTalk.changes)
      lines = source_lines(frame, doit_source, changes)
      return ["(source not available for #{frame.path})\n", nil, 1] unless lines

      first = 1
      if lines.size > 120
        first = [frame.lineno - 40, 1].max
        lines = lines[(first - 1), 81] || []
      end
      current = frame.lineno - first + 1
      [lines.join, (1..lines.size).cover?(current) ? current : nil, first]
    end

    def source_lines(frame, doit_source, changes)
      path = frame.path.to_s
      if path.match?(/\A(rubytalk|changes\.rb):/)
        entry = method_entry(frame, changes)
        entry&.source&.lines
      elsif File.file?(path)
        File.readlines(path, encoding: 'UTF-8')
      elsif path.match?(EVAL_LABEL) && doit_source
        doit_source.lines
      end
    rescue SystemCallError, EncodingError
      nil
    end

    # "block (2 levels) in Foo#bar" -> "bar"
    def method_name(label)
      plain = label.to_s.sub(/\Ablock (\(\d+ levels\) )?in /, '')
      plain.split(/[#.]/).last if plain.match?(/\A.+[#.][^#.]+\z/) || plain.match?(/\A[\w?!=]+\z/)
    end

    def method_entry(frame, changes)
      target = frame.path.to_s.split(':', 2).last
      name = method_name(frame.label) or return nil
      changes&.find_method(target, :instance, name) || changes&.find_method(target, :class, name)
    end

    # [class, side, "name"] for the method running in +frame+, or nil when it is not a method
    # we can name (top level, a block at top level ...).
    def method_target(frame, changes = RubyTalk.changes)
      name = method_name(frame.label) or return nil
      path = frame.path.to_s
      if (match = path.match(/\A(?:rubytalk|changes\.rb):(.+)\z/))
        klass = Reflection.lookup(match[1]) or return nil
        side = changes&.find_method(match[1], :class, name) && !changes.find_method(match[1], :instance, name) ? :class : :instance
        return [klass, side, name]
      end

      plain = frame.label.to_s.sub(/\Ablock (\(\d+ levels\) )?in /, '')
      if (owner = plain.match(/\A(.+)([#.])[^#.]+\z/)) && (klass = Reflection.lookup(owner[1]))
        return [klass, owner[2] == '.' ? :class : :instance, name]
      end

      receiver_target(frame, name)
    end

    # Older Rubies label frames with just the method name: ask the binding.
    def receiver_target(frame, name)
      receiver = frame.binding&.receiver or return nil
      return [receiver, :class, name] if receiver.is_a?(Module)

      [receiver.class, :instance, name]
    end
  end
end
