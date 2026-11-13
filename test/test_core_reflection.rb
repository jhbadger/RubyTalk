# frozen_string_literal: true

# Class comments, hierarchies and the reflection layer behind the Browser.
#   ruby test/test_core_reflection.rb

require_relative 'support/core_case'

class CoreReflectionTest < CoreCase
  # --- Class comments ---------------------------------------------------

  DOC = "# A documented class used by the class-comment tests.\n# It has a second line.\n"

  def test_split_comment
    assert_equal ["# a\n# b\n", "class X\nend\n"], RubyTalk::Source.split_comment("# a\n# b\nclass X\nend\n")
    assert_equal ["# a\n", "class X\nend\n"], RubyTalk::Source.split_comment("\n\n# a\nclass X\nend\n"), 'leading blanks skipped'
    assert_equal ['', "class X\nend\n"], RubyTalk::Source.split_comment("class X\nend\n")
    assert_equal ["# only\n", ''], RubyTalk::Source.split_comment("# only\n")
    assert_equal ['', ''], RubyTalk::Source.split_comment('')
  end

  def test_class_comment_comes_from_the_source_file_for_ruby_classes
    assert_equal DOC, RubyTalk::Reflection.class_comment(RtDocumented, @changes)
    assert_equal "#{DOC}class RtDocumented < Object\nend\n", RubyTalk::Reflection.class_definition(RtDocumented)
    assert_equal '', RubyTalk::Reflection.class_comment(String, @changes), 'C classes have no source file'
    assert_equal "class String < Object\n  include Comparable\nend\n", RubyTalk::Reflection.class_definition(String)
    assert_equal '', RubyTalk::Reflection.file_comment(Class.new), 'anonymous classes do not raise'
  end

  def test_magic_comments_are_not_class_comments
    path = File.join(@dir, 'magic.rb')
    File.write(path, "# frozen_string_literal: true\n# Real doc.\nclass RtMagic\nend\n")
    load path
    assert_equal "# Real doc.\n", RubyTalk::Reflection.file_comment(RtMagic)
  ensure
    drop_classes(:RtMagic)
  end

  def test_editing_the_comment_of_an_existing_class
    shown = RubyTalk::Reflection.class_definition(RtDocumented)
    assert_empty accept(shown).then { @changes.entries }, 'accepting it unchanged logs nothing'

    out = accept("# New words.\nclass RtDocumented < Object\nend\n")
    assert out.ok, out.message
    entry = @changes.open_entry('RtDocumented', 'comment')
    assert_equal "# New words.\nclass RtDocumented < Object\nend\n", entry.source
    assert_equal "# New words.\n", RubyTalk::Reflection.class_comment(RtDocumented, @changes)
    assert_equal "# New words.\nclass RtDocumented < Object\nend\n", RubyTalk::Reflection.class_definition(RtDocumented)

    accept("# Newer words.\nclass RtDocumented < Object\nend\n")
    assert_equal 1, @changes.entries.size, 'editing again replaces the comment entry'

    accept("class RtDocumented < Object\nend\n") # cleared: back to the original
    assert_nil @changes.open_entry('RtDocumented', 'comment')
    assert_equal DOC, RubyTalk::Reflection.class_comment(RtDocumented, @changes)

    accept("# New words.\nclass RtDocumented < Object\nend\n")
    accept(RubyTalk::Reflection.file_comment(RtDocumented) + "class RtDocumented < Object\nend\n") # original text back
    assert_empty @changes.entries
  end

  def test_comment_on_a_c_class_persists_across_a_restart
    accept("# Strings of text.\nclass String < Object\n  include Comparable\nend\n")
    assert_equal "# Strings of text.\n", RubyTalk::Reflection.class_comment(String, @changes)
    assert_match(/\A# Strings of text\.\nclass String < Object\n  include Comparable\nend\n\z/,
                 RubyTalk::Reflection.class_definition(String))
    @changes.save!
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      RubyTalk.setup(#{@dir.inspect})
      print RubyTalk::Reflection.class_comment(String)
    RUBY
    out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.success?, out
    assert_equal "# Strings of text.\n", out.lines.last(1).join
  end

  def test_comment_of_a_class_you_created_travels_with_its_definition
    accept("# Mine.\nclass RtCmt\nend\n")
    assert_equal "# Mine.\nclass RtCmt\nend\n", RubyTalk::Reflection.class_definition(RtCmt)
    accept("# Mine, revised.\nclass RtCmt\nend\n")
    assert_equal "# Mine, revised.\nclass RtCmt\nend\n", RubyTalk::Reflection.class_definition(RtCmt)
    assert_equal [:class], @changes.entries.map(&:kind)
  ensure
    drop_classes(:RtCmt)
  end

  def test_new_class_template_has_the_comment_above_the_class
    assert_equal "# Describe NewClass here.\nclass NewClass < Object\nend\n", RubyTalk::Reflection.new_class_template
    out = accept(RubyTalk::Reflection.new_class_template.sub('class NewClass', 'class RtFromTemplate'))
    assert out.ok, out.message
    assert_match(/\A# Describe NewClass here\.\nclass RtFromTemplate/, RubyTalk::Reflection.class_definition(RtFromTemplate))
  ensure
    drop_classes(:RtFromTemplate)
  end

  # --- Hierarchy --------------------------------------------------------

  def test_hierarchy_of_a_class_is_its_ancestors_then_all_its_subclasses
    make_class(:RtH1)
    make_class(:RtH2, RtH1)
    make_class(:RtH3, RtH2)
    make_class(:RtH4, RtH1)
    Class.new(RtH1) # anonymous classes are not listed
    rows = RubyTalk::Reflection.hierarchy(RtH1)
    assert_equal ['BasicObject', '  Object', '    RtH1', '      RtH2', '        RtH3', '      RtH4'], rows.map(&:label)
    assert_equal [0, 1, 2, 3, 4, 3], rows.map(&:depth)
    assert_equal ['BasicObject', '  Object', '    RtH1', '      RtH2', '        RtH3'],
                 RubyTalk::Reflection.hierarchy(RtH2).map(&:label), 'siblings are not part of it'
    assert_equal %w[BasicObject Object Numeric Integer], RubyTalk::Reflection.hierarchy(Integer).map { |r| r.klass.name }
  ensure
    drop_classes(:RtH4, :RtH3, :RtH2, :RtH1)
  end

  def test_hierarchy_of_a_module_lists_the_classes_that_include_it_directly
    Object.const_set(:RtMod, Module.new)
    make_class(:RtIncA) { include RtMod }
    make_class(:RtIncB, RtIncA) # inherits the include: not a direct includer
    assert_equal ['RtMod', '  RtIncA'], RubyTalk::Reflection.hierarchy(RtMod).map(&:label)
    assert_includes RubyTalk::Reflection.hierarchy(Comparable).map { |row| row.klass.name }, 'String'
  ensure
    drop_classes(:RtIncB, :RtIncA, :RtMod)
  end

  def test_hierarchy_of_object_is_capped_and_fast
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rows = RubyTalk::Reflection.hierarchy(Object)
    assert_equal 'BasicObject', rows.first.label
    assert_operator rows.size, :<=, RubyTalk::Reflection::MAX_HIERARCHY
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2.0
  end

  # --- Reflection -------------------------------------------------------

  def test_categories
    accept("class RtCat\nend\n")
    catalog = RubyTalk::Reflection.catalog(@changes)
    assert_equal 'User-Defined', catalog.names.first
    assert_equal 'All Classes', catalog.names.last
    assert_includes catalog.classes_in('User-Defined'), RtCat
    assert_includes catalog.classes_in('Collections'), Array
    assert_includes catalog.classes_in('Exceptions'), ArgumentError
    assert_includes catalog.classes_in('Modules'), Math unless catalog.classes_in('Numbers').include?(Math)
    assert_includes catalog.classes_in('All Classes'), RtCat
  ensure
    Object.send(:remove_const, :RtCat) if defined?(RtCat)
  end

  # A `require` of a library (BioRuby's `require 'bio'`, say) makes its classes browsable.
  def test_required_library_classes_and_methods_are_browsable
    File.write(File.join(@dir, 'rtfakebio.rb'), <<~RUBY)
      # A sequence of nucleotides.
      module RtFakeBio
        class Sequence
          def complement
            reverse
          end
        end
        class Error < StandardError; end
      end
    RUBY
    refute defined?(RtFakeBio), 'not loaded until required'
    $LOAD_PATH.unshift(@dir)
    require 'rtfakebio'
    catalog = RubyTalk::Reflection.catalog(@changes)
    assert_includes catalog.classes_in('Modules'), RtFakeBio
    assert_includes catalog.classes_in('Nested: RtFakeBio'), RtFakeBio::Sequence
    assert_includes catalog.classes_in('All Classes'), RtFakeBio::Error
    refute_includes catalog.classes_in('User-Defined'), RtFakeBio::Sequence, 'required, not created in RubyTalk'
    assert_includes RubyTalk::Reflection.methods_for(RtFakeBio::Sequence, :instance, :public, false), :complement
    assert_match(/def complement/, RubyTalk::Reflection.method_text(RtFakeBio::Sequence, :instance, :complement))
  ensure
    $LOAD_PATH.delete(@dir)
    Object.send(:remove_const, :RtFakeBio) if defined?(RtFakeBio)
  end

  # BioRuby declares most classes with `autoload`: they are listed before they are loaded.
  def test_pending_autoloads_are_listed_and_can_be_loaded
    File.write(File.join(@dir, 'rtlazy_seq.rb'), "module RtLazy\n  class Seq\n    def length2\n      2\n    end\n  end\nend\n")
    File.write(File.join(@dir, 'rtlazy_broken.rb'), "raise LoadError, 'cannot load such file -- missing_dependency'\n")
    Object.const_set(:RtLazy, Module.new)
    RtLazy.autoload(:Seq, File.join(@dir, 'rtlazy_seq.rb'))
    RtLazy.autoload(:Broken, File.join(@dir, 'rtlazy_broken.rb'))
    refute_includes RubyTalk::Reflection.all_modules.map { |m| RubyTalk::Reflection.name_of(m) }, 'RtLazy::Seq'

    pending = RubyTalk::Reflection.catalog(@changes).classes_in('Nested: RtLazy')
    seq = pending.find { |entry| entry.name == 'RtLazy::Seq' }
    assert_kind_of RubyTalk::Reflection::Pending, seq
    assert_equal 'RtLazy::Seq  (not loaded)', RubyTalk::Reflection.list_label(seq)
    assert_includes RubyTalk::Reflection.catalog(@changes).classes_in('All Classes'), seq

    assert_raises(LoadError) { RubyTalk::Reflection.load_pending(pending.find { |e| e.name == 'RtLazy::Broken' }) }

    assert_equal RtLazy::Seq, RubyTalk::Reflection.load_pending(seq)
    after = RubyTalk::Reflection.catalog(@changes).classes_in('Nested: RtLazy')
    assert_includes after, RtLazy::Seq
    refute(after.any? { |entry| entry.is_a?(RubyTalk::Reflection::Pending) && entry.name == 'RtLazy::Seq' })
    assert_includes RubyTalk::Reflection.methods_for(RtLazy::Seq, :instance, :public, false), :length2
  ensure
    Object.send(:remove_const, :RtLazy) if defined?(RtLazy)
  end

  def test_graphics_classes_are_listed_in_their_own_category
    catalog = RubyTalk::Reflection.catalog(@changes)
    assert_includes catalog.names, 'Graphics-Primitives'
    %w[Point Rectangle Color Form BitBlt Pen Path Line Arc Circle Spline Font Cursor].each do |name|
      assert_includes catalog.classes_in('Graphics-Primitives'), Object.const_get(name), name
    end
    assert_includes catalog.classes_in('Graphics-Primitives'), Dependents
    assert_match(/Rectangle/, RubyTalk::Reflection.method_text(Point, :instance, :corner), 'their source is browsable')
  end

  def test_methods_for_and_text
    names = RubyTalk::Reflection.methods_for(String, :instance, :public, false)
    assert_includes names, :upcase
    assert_includes RubyTalk::Reflection.methods_for(String, :class, :all, false), :try_convert
    refute_includes RubyTalk::Reflection.methods_for(String, :class, :all, false), :new
    assert_includes RubyTalk::Reflection.methods_for(String, :class, :all, true), :new
    refute_includes RubyTalk::Reflection.methods_for(String, :instance, :private, false), :upcase

    text = RubyTalk::Reflection.method_text(String, :instance, :upcase)
    assert_match(/implemented in C/, text)
    assert_match(/# def upcase\(\*args\)/, text)
    assert_equal RubyTalk::Reflection.method_template, RubyTalk::Reflection.method_text(String, :instance, :nope)
  end

  def test_user_method_text_comes_from_changes
    accept("class RtShow\nend\n")
    accept("# note\ndef hello\n  :hi\nend\n", klass: RtShow)
    text = RubyTalk::Reflection.method_text(RtShow, :instance, :hello)
    assert_equal "# note\ndef hello\n  :hi\nend\n", text
    assert_equal '* hello', RubyTalk::Reflection.method_label(RtShow, :instance, :hello, @changes)
  ensure
    Object.send(:remove_const, :RtShow) if defined?(RtShow)
  end

  def test_class_definition_text
    assert_equal "class Integer < Numeric\n  include Comparable\nend\n".lines.first,
                 RubyTalk::Reflection.class_definition(Integer).lines.first
    assert_equal "module Comparable\nend\n", RubyTalk::Reflection.class_definition(Comparable)
  end

  def test_owner_label_for_class_side
    method = String.method(:new).unbind
    assert_match(/class side|Class/, RubyTalk::Reflection.owner_label(method.owner))
  end
end
