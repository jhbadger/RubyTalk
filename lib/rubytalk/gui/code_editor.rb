# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    # A text pane with Smalltalk's evaluation commands:
    #   do it       evaluate the selection (or the current line)
    #   print it    evaluate and insert the result after the selection
    #   inspect it  evaluate and open an Inspector on the result
    #   browse it   evaluate and open a Browser on the result's class
    # plus Accept (when the owner supplies an on_accept callback).
    #
    # +evaluator+ is a callable taking source text and returning an
    # Evaluator::Result; it decides the context (workspace binding, inspected
    # object ...). With highlight: true the text is syntax-coloured as Ruby
    # (see Highlighter); the Transcript is left plain because it mostly holds output.
    class CodeEditor
      attr_reader :frame, :text

      # :light or :dark once highlighting is set up (the palette in use), else nil.
      attr_reader :palette_name

      def initialize(parent, evaluator:, width: 80, height: 12, wrap: 'none', on_accept: nil, highlight: false)
        @evaluator = evaluator
        @on_accept = on_accept
        @highlight = false
        @highlight_ready = false
        @frame, @text = GUI.scrolled_text(parent, width: width, height: height, wrap: wrap)
        build_menu
        bind_keys
        bind_popup
        setup_highlighting if highlight
      end

      def can_accept?
        !@on_accept.nil?
      end

      def accept
        @on_accept&.call
      end

      def contents
        @text.get('1.0', 'end-1c').to_s
      end

      def set_contents(string)
        @text.delete('1.0', 'end')
        @text.insert('1.0', string.to_s.dup)
        # Tk leaves the cursor after inserted text; put it back at the start so
        # "do it" with no selection uses the first line.
        Tk.tk_call(@text.path, 'mark', 'set', 'insert', '1.0')
        rehighlight
      end

      # Switch Ruby colouring off (e.g. while showing a diff) or back on.
      def highlighting=(flag)
        @highlight = flag && @highlight_ready
        @highlight ? rehighlight : clear_highlighting
      end

      def clear_highlighting
        return unless @highlight_ready

        Highlighter::TAGS.each { |tag| Tk.tk_call(@text.path, 'tag', 'remove', "rt_#{tag}", '1.0', 'end') }
      end

      # Recolour the whole text. Cheap enough to run on every key release; texts
      # over Highlighter::MAX_SOURCE characters are left uncoloured.
      def rehighlight
        return unless @highlight

        Highlighter::TAGS.each { |tag| Tk.tk_call(@text.path, 'tag', 'remove', "rt_#{tag}", '1.0', 'end') }
        Highlighter.ranges_by_tag(contents).each do |tag, ranges|
          Tk.tk_call(@text.path, 'tag', 'add', "rt_#{tag}", *ranges)
        end
      end

      def focus
        @text.focus
      end

      def do_it
        evaluate_selection
        nil
      end

      def print_it
        result, _first, last = evaluate_selection
        return unless result&.ok

        insert_selected(last, " #{GUI.print_string(result.value)}")
      end

      def inspect_it
        result, = evaluate_selection
        Inspector.new(result.value) if result&.ok
      end

      def browse_it
        result, = evaluate_selection
        return unless result&.ok

        target = result.value
        Browser.open(target.is_a?(Module) ? target : target.class)
      end

      # Evaluate the selection and open the hierarchy of the class it gives (or of its class).
      def hierarchy_of_it
        result, = evaluate_selection
        return unless result&.ok

        target = result.value
        Browser.open(target.is_a?(Module) ? target : target.class, hierarchy: true)
      end

      # The selection (or the word at the cursor) taken as a method name, not evaluated.
      def implementors_of_it
        selector = selector_text
        GUI.show_method_list(:implementors, selector) if selector
      end

      def senders_of_it
        selector = selector_text
        GUI.show_method_list(:senders, selector) if selector
      end

      private

      def selector_text
        raw = selected_text.to_s.strip
        raw = @text.get('insert wordstart', 'insert wordend').to_s.strip if raw.empty?
        raw = raw.sub(/\A:/, '').sub(/\A[A-Z][\w:]*[#.](?=\S)/, '')
        raw.empty? ? nil : raw
      end

      def selected_text
        @text.get('sel.first', 'sel.last').to_s
      rescue StandardError
        nil # nothing selected
      end

      # [source, first_index, last_index]: the selection, else the current line.
      def current_expression
        selection = selected_text
        if selection && !selection.empty?
          [selection, @text.index('sel.first').to_s, @text.index('sel.last').to_s]
        else
          [@text.get('insert linestart', 'insert lineend').to_s,
           @text.index('insert linestart').to_s, @text.index('insert lineend').to_s]
        end
      end

      def evaluate_selection
        source, first, last = current_expression
        return nil if source.strip.empty?

        if Evaluator.busy?
          ::Transcript.show_cr("Something is already running: press #{MOD_LABEL}-. to stop it first.")
          return nil
        end

        result = @evaluator.call(source)
        GUI.notify_error(result.error) unless result.ok
        [result, first, last]
      end

      # Insert text after +index+ and select it, so typing replaces it.
      def insert_selected(index, string)
        @text.insert(index, string.dup)
        @text.tag_remove('sel', '1.0', 'end')
        @text.tag_add('sel', index, "#{index}+#{string.size}c")
        rehighlight
      end

      def setup_highlighting
        @highlight = true
        @highlight_ready = true
        @palette_name = dark_background? ? :dark : :light
        palette = Highlighter::PALETTES.fetch(@palette_name)
        Highlighter::TAGS.each do |tag|
          Tk.tk_call(@text.path, 'tag', 'configure', "rt_#{tag}", '-foreground', palette.fetch(tag).dup)
        end
        # Our tags are newer than the selection tag, so put the selection back on top.
        Tk.tk_call(@text.path, 'tag', 'raise', 'sel')
        @text.bind('KeyRelease') { GUI.safely { rehighlight } }
        @text.bind('ButtonRelease-2') { GUI.safely { rehighlight } } # middle-click paste
      end

      # Pick the palette from the actual background colour (light or dark appearance).
      def dark_background?
        background = Tk.tk_call(@text.path, 'cget', '-background').to_s.dup
        red, green, blue = Tk.tk_call('winfo', 'rgb', @text.path, background).to_s.split.map(&:to_i)
        return false unless blue

        (((0.299 * red) + (0.587 * green) + (0.114 * blue)) / 65_535.0) < 0.5
      rescue StandardError
        false
      end

      def command_keys
        @command_keys ||= {
          'd' => :do_it, 'p' => :print_it, 'i' => :inspect_it, 'b' => :browse_it,
          'm' => :implementors_of_it, 'n' => :senders_of_it
        }
      end

      def bind_keys
        command_keys.each { |letter, action| bind_command(letter) { send(action) } }
        bind_command('s') { accept } if can_accept?
        bind_command('period') { GUI.interrupt } # Cmd-. (Ctrl-. elsewhere): stop the running code
      end

      def bind_command(letter, &action)
        @text.bind("#{MODIFIER}-Key-#{letter}") do
          GUI.safely(&action)
          Tk.callback_break
        end
      end

      def build_menu
        @menu = TkMenu.new(@text, tearoff: false)
        GUI.add_item(@menu, 'Do it', "#{MOD_LABEL}-D") { do_it }
        GUI.add_item(@menu, 'Print it', "#{MOD_LABEL}-P") { print_it }
        GUI.add_item(@menu, 'Inspect it', "#{MOD_LABEL}-I") { inspect_it }
        GUI.add_item(@menu, 'Browse it', "#{MOD_LABEL}-B") { browse_it }
        GUI.add_item(@menu, 'Hierarchy of it') { hierarchy_of_it }
        GUI.add_item(@menu, 'Implementors of it', "#{MOD_LABEL}-M") { implementors_of_it }
        GUI.add_item(@menu, 'Senders of it', "#{MOD_LABEL}-N") { senders_of_it }
        if can_accept?
          @menu.add('separator')
          GUI.add_item(@menu, 'Accept', "#{MOD_LABEL}-S") { accept }
        end
        @menu.add('separator')
        %w[Cut Copy Paste].each do |name|
          GUI.add_item(@menu, name) do
            GUI.generate_event(name)
            rehighlight
          end
        end
      end

      def bind_popup
        %w[Button-2 Button-3 Control-Button-1].each do |event|
          @text.bind(event) do
            GUI.safely { GUI.popup(@menu) }
            Tk.callback_break
          end
        end
      end
    end
  end
end
