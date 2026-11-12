# frozen_string_literal: true

# Headless tests for "Explain it" (RubyTalk::Explainer). Run:  ruby test/test_explainer.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'rubytalk'

class ExplainerTest < Minitest::Test
  include RubyTalk

  METHOD = <<~RUBY
    def deposit(amount, note = helper)
      total = @balance + amount
      [1].each { |n| total += n }
      begin
        log
      rescue => error
        error
      end
      total
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir('rubytalk-explain')
    RubyTalk.changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
  end

  def teardown
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :RtExAccount) if defined?(RtExAccount)
    $rt_ex_global = nil
  end

  def explain(word, **context)
    Explainer.explain(word, source: METHOD, **context)
  end

  # --- finding the word ------------------------------------------------------

  def test_token_at_finds_the_word_under_or_just_after_the_cursor
    line = 'x = @balance + foo?(1)'
    assert_equal '@balance', Explainer.token_at(line, 6)
    assert_equal '@balance', Explainer.token_at(line, 4), 'at the start of the word'
    assert_equal '@balance', Explainer.token_at(line, 12), 'just after the word'
    assert_equal 'foo?', Explainer.token_at(line, 18)
    assert_equal 'Foo::Bar', Explainer.token_at('Foo::Bar.new', 3)
    assert_equal '@@count', Explainer.token_at('@@count += 1', 2)
    assert_equal '$stdout', Explainer.token_at('$stdout.puts', 3)
    assert_equal ':name', Explainer.token_at('send(:name)', 7)
  end

  def test_token_at_answers_nil_when_there_is_nothing
    assert_nil Explainer.token_at('   ', 1)
    assert_nil Explainer.token_at('', 0)
  end

  def test_nothing_or_several_words_is_explained_politely
    assert_match(/Nothing to explain/, Explainer.explain(''))
    assert_match(/Nothing to explain/, Explainer.explain('   '))
    assert_match(/Select one word/, Explainer.explain('two words'))
  end

  # --- variables -------------------------------------------------------------

  def test_parameters_and_locals_are_found_in_the_pane_text
    assert_match(/amount is a parameter of method deposit \(line 1\)/, explain('amount'))
    assert_match(/note is a parameter of method deposit/, explain('note'))
    assert_match(/total is a local variable of method deposit, first assigned on line 2/, explain('total'))
    assert_match(/n is a block parameter of method deposit \(line 3\)/, explain('n'))
    assert_match(/error is a local variable of method deposit, first assigned on line 6/, explain('error'))
  end

  def test_a_call_in_a_default_value_is_not_mistaken_for_a_parameter
    text = explain('helper')
    refute_match(/parameter/, text)
    assert_match(/helper/, text)
  end

  def test_a_name_the_text_never_declares_is_a_selector
    assert_match(/rt_ex_nothing: no class implements a method with this name/, explain('rt_ex_nothing'))
    assert_match(/upcase is a message selector. Implemented by \d+ classes?:.*String#upcase/, explain('upcase'))
  end

  def test_instance_variable_says_where_it_is_used
    Compiler.accept("class RtExAccount\n  attr_reader :balance\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def initialize\n  @balance = 0\nend\n", klass: RtExAccount, changes: RubyTalk.changes)
    Compiler.accept("def deposit(n)\n  @balance += n\nend\n", klass: RtExAccount, changes: RubyTalk.changes)
    Compiler.accept("def other\n  # @balance in a comment\n  1\nend\n", klass: RtExAccount, changes: RubyTalk.changes)

    text = explain('@balance', klass: RtExAccount)
    assert_match(/@balance is an instance variable of RtExAccount\./, text)
    assert_match(/Used by: deposit, initialize\z|Used by: deposit, initialize\n/, text, 'comments do not count as uses')
    assert_match(/Reader method balance exists/, text)
    refute_match(/Writer method/, text)
    assert_match(/instance variable.*Pick a class/, explain('@balance'), 'without a class it says what the word is')
  end

  def test_class_and_global_variables
    $rt_ex_global = [1, 2]
    assert_match(/\$rt_ex_global is a global variable\.\nValue: \[1, 2\]/, explain('$rt_ex_global'))
    assert_match(/nothing has assigned it/, explain('$rt_ex_never_set'))
    assert_match(/@@total is a class variable: one value shared/, explain('@@total'))
    Object.const_set(:RtExAccount, Class.new { class_variable_set(:@@total, 5) })
    assert_match(/class variable of RtExAccount.*Value: 5/m, explain('@@total', klass: RtExAccount))
  end

  # --- constants, keywords and symbols ---------------------------------------

  def test_classes_and_modules
    text = explain('String')
    assert_match(/String is a class \(built in or loaded from a library\)\./, text)
    assert_match(/Superclass: Object\./, text)
    assert_match(/Includes: Comparable\./, text)
    assert_match(/Comparable is a module/, explain('Comparable'))
    assert_match(/File::Stat is a class/, explain('File::Stat'))
  end

  def test_a_class_made_in_rubytalk_says_so_and_shows_its_comment
    Compiler.accept("# Holds money.\nclass RtExAccount\nend\n", changes: RubyTalk.changes)
    text = explain('RtExAccount')
    assert_match(/created in RubyTalk/, text)
    assert_match(/Comment: Holds money\./, text)
  end

  def test_unknown_constant_and_plain_constant
    assert_match(/nothing by that name is defined here/, explain('RtExNoSuchThing'))
    assert_match(/RbConfig/, explain('RbConfig'))
    assert_match(/ARGV is a constant: \[\]|ARGV is a constant/, explain('ARGV'))
  end

  def test_keywords_and_symbols
    assert_match(/self: the receiver/, explain('self'))
    assert_match(/nil: the only instance of NilClass/, explain('nil'))
    assert_match(/yield: runs the block/, explain('yield'))
    assert_match(/:upcase is a Symbol\.\nupcase is a message selector/, explain(':upcase'))
  end

  # --- selectors ---------------------------------------------------------------

  def test_selector_resolved_against_the_class_in_view
    text = explain('upcase', klass: String)
    assert_match(/String#upcase resolves to String#upcase: public, arity -1, implemented in C\./, text)
    assert_match(/Implemented by \d+ classes/, text)
    assert_match(/String\.new resolves to/, explain('new', klass: String, side: :class))
  end

  def test_private_methods_are_called_private
    assert_match(/Object#puts resolves to Kernel#puts: private/, explain('puts', klass: Object))
  end

  def test_long_implementor_lists_are_cut_short
    text = explain('to_s')
    assert_match(/Implemented by \d+ classes: /, text)
    assert_match(/and \d+ more\./, text)
    assert_match(/Edit > Implementors of it/, text)
  end

  def test_operators_are_selectors_too
    assert_match(/\+ is a message selector\. Implemented by \d+ classes?:.*Integer#\+/, explain('+'))
  end

  # --- Source.mentions_variable? -------------------------------------------------

  def test_mentions_variable_ignores_comments_and_strings
    assert Source.mentions_variable?("def a\n  @x + 1\nend", '@x')
    refute Source.mentions_variable?("def a\n  # @x\n  '@x'\nend", '@x')
    assert Source.mentions_variable?('@@n += 1', '@@n')
    refute Source.mentions_variable?('@xy = 1', '@x'), 'a longer name is a different variable'
  end
end
