# frozen_string_literal: true

# File out and file in of plain Ruby.
#   ruby test/test_core_exchange.rb

require_relative 'support/core_case'

class CoreExchangeTest < CoreCase
  def drop_exchange_classes
    drop_classes(:RtShape, :RtHelp, :RtOne, :RtStructy, :RtEx, :RtExMod, :RtLibEx, :RtNested)
    String.send(:remove_method, :rt_shout) if String.method_defined?(:rt_shout)
  end

  # --- File out and file in ----------------------------------------------------

  SHAPES = <<~'RUBY'
    # A shape.
    class RtShape
      attr_reader :sides

      def initialize(sides)
        @sides = sides
      end

      # The area (always 0 here).
      def area
        0
      end

      def self.square
        new(4)
      end

      class << self
        def triangle
          new(3)
        end
      end

      class Inner
      end
    end

    module RtHelp
      def helper
        :h
      end
    end

    class String
      def rt_shout
        upcase + '!'
      end
    end

    puts 'top-level code runs'
  RUBY


  def test_file_in_takes_a_ruby_file_apart_into_changes
    summary = RubyTalk::Exchange.file_in(SHAPES, @changes, label: 'shapes.rb')
    assert summary.ok?, summary.errors.inspect
    assert_equal [2, 6, 2, 1], [summary.classes, summary.methods, summary.statements, summary.top_level]
    assert_equal '2 classes created, 6 methods, 2 other class statements, 1 top-level statement run', summary.to_s

    assert_equal "def initialize(sides)\n  @sides = sides\nend\n", @changes.find_method('RtShape', :instance, 'initialize').source
    assert_equal "# The area (always 0 here).\ndef area\n  0\nend\n", @changes.find_method('RtShape', :instance, 'area').source
    assert @changes.find_method('RtShape', :class, 'square'), 'def self.x is a class-side method'
    assert_equal "def triangle\n  new(3)\nend\n", @changes.find_method('RtShape', :class, 'triangle').source
    assert_equal "# A shape.\nclass RtShape\nend\n", @changes.class_entry('RtShape').source
    assert @changes.user_defined?('RtShape')
    assert_equal [3, 3, 4], [RtShape.new(3).sides, RtShape.triangle.sides, RtShape.square.sides]
    assert_equal RtShape::Inner, RtShape.const_get(:Inner), 'a nested class lands inside the class'
    assert_equal :h, Object.new.extend(RtHelp).helper
    assert_equal 'A!', 'a'.rt_shout
    assert_includes Transcript.buffer, 'top-level code runs'
    assert(@changes.entries.none? { |e| e.target == 'String' && %i[class open].include?(e.kind) },
           'a method added to an existing class makes no class entry')
    assert_equal 'rt_shout', @changes.find_method('String', :instance, 'rt_shout').key
  ensure
    drop_exchange_classes
  end

  def test_file_out_is_plain_ruby_that_loads_without_rubytalk
    accept("# Greets.\nclass RtEx\nend\n")
    accept("def hello\n  :hello\nend\n", klass: RtEx)
    accept("def build\n  new\nend\n", klass: RtEx, side: :class)
    accept("def self.make\n  :made\nend\n", klass: RtEx)
    accept("attr_accessor :x\n", klass: RtEx)
    accept("module RtExMod\nend\n")
    accept("def mod_method\n  :from_module\nend\n", klass: RtExMod)
    Object.const_set(:RtLibEx, Class.new { def old = :old })
    RubyTalk::Compiler.remove_method(RtLibEx, :instance, 'old', @changes)

    text = RubyTalk::Exchange.all_source(@changes)
    assert_nil RubyTalk::Source.syntax_error(text), 'it is valid Ruby'
    assert_includes text, "# Greets.\nclass RtEx\nend"
    assert_includes text, "class RtEx\n  class << self\n    def build\n      new\n    end\n  end\nend"
    assert_includes text, "module RtExMod\n  def mod_method"
    assert_match(/RtLibEx\.send\(:remove_method, :old\) if /, text)
    refute_includes text, '#!rubytalk', 'not RubyTalk\'s own format'

    path = File.join(@dir, 'filed_out.rb')
    File.write(path, text)
    script = <<~RUBY
      class RtLibEx; def old; :old; end; end
      load #{path.inspect}
      e = RtEx.new
      e.x = 5
      puts [e.hello, RtEx.build.class, RtEx.make, e.x, Object.new.extend(RtExMod).mod_method, RtLibEx.new.respond_to?(:old)].inspect
      puts defined?(RubyTalk).inspect
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal '[:hello, RtEx, :made, 5, :from_module, false]', out.lines[0].strip
    assert_equal 'nil', out.lines[1].strip, 'it needs no RubyTalk'
  ensure
    drop_exchange_classes
  end

  def test_file_out_then_file_in_round_trips_in_a_fresh_process
    RubyTalk::Exchange.file_in(SHAPES, @changes, label: 'shapes.rb')
    path = File.join(@dir, 'shapes_out.rb')
    File.write(path, RubyTalk::Exchange.all_source(@changes))
    other = File.join(@dir, 'other')
    FileUtils.mkdir_p(other)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      RubyTalk.setup(#{other.inspect})
      summary = RubyTalk::Exchange.file_in_path(#{path.inspect}, RubyTalk.changes)
      puts summary.ok?, summary.methods, summary.classes
      puts [RtShape.new(3).sides, RtShape.triangle.sides, RtShape.square.sides, 'a'.rt_shout].inspect
      RubyTalk.changes.save!
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    lines = out.lines.map(&:strip)
    assert_equal %w[true 6 2], lines.first(3)
    assert_equal '[3, 3, 4, "A!"]', lines[3]
    saved = File.read(File.join(other, 'changes.rb'))
    assert_includes saved, 'kind=class target=RtShape created=true'
    assert_includes saved, 'kind=method target=RtShape side=class key=triangle'
  ensure
    drop_exchange_classes
  end

  def test_class_source_is_one_class_and_nil_when_nothing_was_recorded
    accept("class RtEx\nend\n")
    accept("def hello\n  :hello\nend\n", klass: RtEx)
    accept("class RtNested\nend\n")
    text = RubyTalk::Exchange.class_source(RtEx, @changes)
    assert_includes text, 'def hello'
    refute_includes text, 'RtNested'
    assert_nil RubyTalk::Exchange.class_source(Comparable, @changes)
  ensure
    drop_exchange_classes
  end

  def test_file_in_of_rubytalks_own_format
    accept("class RtEx\nend\n")
    accept("def hello\n  :hello\nend\n", klass: RtEx)
    text = @changes.to_text
    drop_exchange_classes
    other = RubyTalk::ChangeSet.new(File.join(@dir, 'other.rb'))
    summary = RubyTalk::Exchange.file_in(text, other)
    assert summary.ok?, summary.errors.inspect
    assert_equal [1, 1], [summary.classes, summary.methods]
    assert_equal :hello, RtEx.new.hello
    assert_equal %w[class method], other.entries.map { |e| e.kind.to_s }
  ensure
    drop_exchange_classes
  end

  def test_file_in_reports_errors_and_carries_on
    broken = RubyTalk::Exchange.file_in("class Broken\n  def (\nend\n", @changes)
    refute broken.ok?
    assert_match(/SyntaxError/, broken.errors.first)
    assert_empty @changes.entries, 'a file that does not parse changes nothing'

    text = "raise 'top level failed'\n\nclass RtOne\n  attr_reader 1\n  def fine\n    :fine\n  end\nend\n"
    summary = RubyTalk::Exchange.file_in(text, @changes)
    assert_equal 2, summary.errors.size, summary.errors.inspect
    assert_match(/top level failed/, summary.errors.first)
    assert_match(/TypeError/, summary.errors.last)
    assert_equal :fine, RtOne.new.fine, 'the rest of the class was still filed in'
  ensure
    drop_exchange_classes
  end

  def test_classes_with_unusual_headers_are_filed_in_whole
    text = "class RtOne; def x; 1; end; end\n\nclass RtStructy < Struct.new(:a)\n  def b\n    a\n  end\nend\n"
    summary = RubyTalk::Exchange.file_in(text, @changes)
    assert summary.ok?, summary.errors.inspect
    assert_equal [2, 0], [summary.classes, summary.methods]
    assert_equal 1, RtOne.new.x
    assert_equal 7, RtStructy.new(7).b
    assert_equal [:class, :class], @changes.entries.map(&:kind)
    assert_includes @changes.class_entry('RtStructy').source, 'Struct.new(:a)'
  ensure
    drop_exchange_classes
  end

  def test_nested_classes_and_modules_are_defined_inside_their_class
    text = "class RtNested\n  module Deep\n    def self.id\n      :deep\n    end\n  end\n\n  class Leaf < Object\n  end\nend\n"
    summary = RubyTalk::Exchange.file_in(text, @changes)
    assert summary.ok?, summary.errors.inspect
    assert_equal :deep, RtNested::Deep.id
    assert_equal RtNested::Leaf, RtNested.const_get(:Leaf)
    refute defined?(::Deep), 'not defined at the top level'
  ensure
    drop_exchange_classes
  end

  def test_export_from_the_command_line
    accept("class RtEx\nend\n")
    accept("def hello\n  :hello\nend\n", klass: RtEx)
    @changes.save!
    out_path = File.join(@dir, 'exported.rb')
    out, status = Open3.capture2e(RbConfig.ruby, File.expand_path('../bin/rubytalk', __dir__), '--dir', @dir, '--export', out_path)
    assert status.success?, out
    assert_equal "#{out_path}\n", out
    exported = File.read(out_path)
    assert_includes exported, 'def hello'
    assert_nil RubyTalk::Source.syntax_error(exported)
  ensure
    drop_exchange_classes
  end

  def test_file_out_header_and_summary_pluralisation
    assert_match(/\A# Filed out from RubyTalk #{Regexp.escape(RubyTalk::VERSION)} on \d{4}-\d\d-\d\d \d\d:\d\d UTC\./,
                 RubyTalk::Exchange.all_source(@changes))
    summary = RubyTalk::Exchange::Summary.new
    assert_equal '0 classes created, 0 methods, 0 other class statements, 0 top-level statements run', summary.to_s
    summary.classes = 1
    summary.methods = 1
    summary.statements = 1
    summary.top_level = 1
    summary.errors << 'x'
    assert_equal '1 class created, 1 method, 1 other class statement, 1 top-level statement run; 1 error', summary.to_s
  end
end
