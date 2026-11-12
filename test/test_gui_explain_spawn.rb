# frozen_string_literal: true

# GUI tests for "Explain it" and "Spawn", against the recording stand-in for the tk gem
# (test/fake/tk.rb). Run:  ruby test/test_gui_explain_spawn.rb

$LOAD_PATH.unshift(File.expand_path('fake', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'tmpdir'
require 'rubytalk'
require 'rubytalk/gui'

class GuiExplainSpawnTest < Minitest::Test
  include RubyTalk

  def setup
    @saved_home = ENV.values_at('HOME', 'XDG_CONFIG_HOME')
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk-gui-es')
    RubyTalk.changes = ChangeSet.new(File.join(@dir, 'changes.rb'))
    ENV['HOME'] = @dir # settings go to a temporary home, never the real one
    ENV['XDG_CONFIG_HOME'] = nil
    GUI.reset_layout_state
  end

  def teardown
    ENV['HOME'], ENV['XDG_CONFIG_HOME'] = @saved_home
    FileUtils.remove_entry(@dir)
    Object.send(:remove_const, :RtEsThing) if defined?(RtEsThing)
  end

  def ivar(object, name)
    object.instance_variable_get(name)
  end

  def make_thing
    Compiler.accept("class RtEsThing\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def count\n  @count\nend\n", klass: RtEsThing, changes: RubyTalk.changes)
    Compiler.accept("def bump\n  @count = (@count || 0) + 1\nend\n", klass: RtEsThing, changes: RubyTalk.changes)
  end

  # Select +name+ in the browser's method list.
  def pick_method(browser, name)
    click_protocol_all(browser)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(name))
  end

  def click_protocol_all(browser)
    ivar(browser, :@protocols).box.click(0)
  end

  # Invoke an Edit-menu command of a window by its label, as the user would. (Tk wants unfrozen strings.)
  def invoke_edit(window, label)
    menubar = Tk.tk_call(window.path, +'cget', +'-menu').to_s
    edit = Tk.tk_call(menubar, +'entrycget', +'Edit', +'-menu').to_s
    Tk.tk_call(edit, +'invoke', label.dup)
  end

  # Open a method list for +selector+ and select the hit labelled +label+.
  def list_with(selector, label)
    GUI.show_method_list(:implementors, selector)
    list = GUI.windows.last
    ivar(list, :@list).box.click(ivar(list, :@hits).index { |hit| hit.label == label })
    list
  end

  def menu_labels(editor)
    ivar(editor, :@menu).entries.filter_map { |_, options| options[:label] }
  end

  # --- Explain it -----------------------------------------------------------------

  def test_explain_the_selection_writes_to_the_transcript
    editor = GUI::Workspace.new(text: 'x = String.new').editor
    editor.text.select_text('String')
    text = editor.explain_it
    assert_match(/String is a class/, text)
    assert_match(/^Explain String:\n  String is a class/, Transcript.buffer)
    assert_match(/^  Superclass: Object\./, Transcript.buffer, 'each line is indented under the heading')
  end

  def test_explain_the_word_at_the_cursor_when_nothing_is_selected
    editor = GUI::Workspace.new(text: "total = 1\ntotal + 2").editor
    editor.text.insert_offset = 12 # inside "total" on line 2
    assert_match(/total is a local variable, first assigned on line 1\./, editor.explain_it)
  end

  def test_explain_with_no_word_says_so
    editor = GUI::Workspace.new(text: '   ').editor
    editor.text.insert_offset = 1
    assert_nil editor.explain_it
    assert_match(/Nothing to explain/, Transcript.buffer)
  end

  def test_explain_by_key_and_from_the_menus
    editor = GUI::Workspace.new(text: 'nil').editor
    editor.text.select_text('nil')
    assert_equal :break, editor.text.fire("#{GUI::MODIFIER}-Key-e")
    assert_match(/Explain nil:\n  nil: the only instance of NilClass/, Transcript.buffer)

    assert_includes menu_labels(editor), 'Explain it'
    workspace = GUI::Workspace.new(text: 'true')
    workspace.editor.text.select_text('true')
    invoke_edit(workspace.window, 'Explain it')
    assert_match(/true: the only instance of TrueClass/, Transcript.buffer)
  end

  def test_explain_in_the_browser_knows_the_selected_class
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    pick_method(browser, :bump)
    browser.code.text.select_text('@count')
    text = browser.code.explain_it
    assert_match(/@count is an instance variable of RtEsThing\./, text)
    assert_match(/Used by: bump, count/, text)

    browser.code.text.select_text('bump')
    assert_match(/RtEsThing#bump resolves to RtEsThing#bump: public, arity 0/, browser.code.explain_it)
  end

  def test_explain_in_a_method_list_uses_the_selected_method_class
    make_thing
    list = list_with('bump', 'RtEsThing#bump')
    list.code.text.select_text('@count')
    assert_match(/instance variable of RtEsThing/, list.code.explain_it)
  end

  # --- Spawn: text -------------------------------------------------------------

  def test_spawn_a_workspace_copies_all_of_it
    editor = GUI::Workspace.new(text: "a = 1\nb = 2").editor
    editor.spawn
    spawned = GUI.windows.last
    assert_instance_of GUI::Workspace, spawned
    refute_same editor, spawned.editor
    assert_equal "a = 1\nb = 2", spawned.editor.contents
    assert_equal "a = 1\nb = 2", editor.contents, 'the original is untouched'
  end

  def test_spawn_with_a_selection_takes_only_the_selection
    editor = GUI::Workspace.new(text: "a = 1\nb = 2").editor
    editor.text.select_text('b = 2')
    editor.spawn
    assert_equal 'b = 2', GUI.windows.last.editor.contents
  end

  def test_spawn_is_in_the_menus
    editor = GUI::Workspace.new(text: 'x').editor
    assert_includes menu_labels(editor), 'Spawn'
    workspace = GUI::Workspace.new(text: 'y')
    before = GUI.windows.size
    invoke_edit(workspace.window, 'Spawn')
    assert_equal before + 1, GUI.windows.size
    assert_equal 'y', GUI.windows.last.editor.contents
  end

  # --- Spawn: methods ------------------------------------------------------------

  def test_spawn_method_from_the_browser_opens_a_method_window
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    pick_method(browser, :count)
    browser.send(:spawn_method)
    window = GUI.windows.last
    assert_instance_of GUI::MethodList, window
    assert_equal "def count\n  @count\nend\n", window.code.contents
    assert_equal 1, ivar(window, :@list).box.items.size
    assert_equal ['RtEsThing#count'], ivar(window, :@list).box.items
  end

  def test_spawned_method_window_accepts_in_place
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    pick_method(browser, :count)
    browser.send(:spawn_method)
    window = GUI.windows.last
    window.code.set_contents("def count\n  @count || 0\nend\n")
    window.code.accept
    assert_equal 0, RtEsThing.new.count
    assert_equal "def count\n  @count || 0\nend\n", RubyTalk.changes.find_method('RtEsThing', :instance, 'count').source
  end

  def test_spawning_edited_code_carries_the_edits_and_reverts_the_pane
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    pick_method(browser, :count)
    browser.code.set_contents("def count\n  @count.to_i\nend\n") # not accepted
    browser.code.spawn
    window = GUI.windows.last
    assert_instance_of GUI::MethodList, window
    assert_equal "def count\n  @count.to_i\nend\n", window.code.contents, 'the unaccepted edit is in the new window'
    assert_equal "def count\n  @count\nend\n", browser.code.contents, 'the browser pane is back to the stored source'
    assert_nil RtEsThing.new.count, 'nothing was accepted by spawning'
  end

  def test_spawning_unedited_code_leaves_the_pane_alone
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    pick_method(browser, :count)
    browser.code.spawn
    assert_equal "def count\n  @count\nend\n", browser.code.contents
  end

  def test_spawn_with_no_method_selected_gives_a_workspace
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    browser.code.spawn # the class definition
    assert_instance_of GUI::Workspace, GUI.windows.last
    assert_match(/class RtEsThing/, GUI.windows.last.editor.contents)
    browser.send(:spawn_method) # no method: does nothing
    assert_instance_of GUI::Workspace, GUI.windows.last
  end

  def test_spawn_method_from_the_methods_context_menu_and_a_method_list
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    labels = ivar(ivar(browser, :@methods), :@menu_items).map(&:first)
    assert_includes labels, 'Spawn method'

    list = list_with('bump', 'RtEsThing#bump')
    assert_includes ivar(ivar(list, :@list), :@menu_items).map(&:first), 'Spawn'
    list.send(:spawn)
    assert_equal ['RtEsThing#bump'], ivar(GUI.windows.last, :@list).box.items
    refute_same list, GUI.windows.last

  end

  def test_spawn_in_a_method_list_with_nothing_selected_asks_for_a_method
    GUI.show_method_list(:implementors, 'rt_es_no_such_selector')
    list = GUI.windows.last
    list.send(:spawn)
    assert_equal 'Select a method first.', ivar(list, :@status).options[:text]
  end

  # --- Spawn: class --------------------------------------------------------------

  def test_spawn_class_opens_a_browser_with_just_that_class
    make_thing
    browser = GUI::Browser.open(RtEsThing)
    assert_includes ivar(ivar(browser, :@classes), :@menu_items).map(&:first), 'Spawn class'
    browser.send(:spawn_class)
    spawned = GUI.windows.last
    refute_same browser, spawned
    assert_equal ['RtEsThing'], ivar(spawned, :@classes).box.items
    assert_equal ['Class RtEsThing'], ivar(spawned, :@categories).box.items
    assert_match(/class RtEsThing/, spawned.code.contents, 'the class is selected')
    assert_equal true, ivar(spawned, :@single)
  end

  def test_spawned_class_browser_works_like_a_browser
    make_thing
    GUI::Browser.open(RtEsThing).send(:spawn_class)
    spawned = GUI.windows.last
    click_protocol_all(spawned)
    assert_equal %i[bump count], ivar(ivar(spawned, :@methods), :@values).first(2)
    spawned.code.set_contents("def double\n  2\nend\n")
    spawned.code.accept
    assert_equal 2, RtEsThing.new.double
    assert_equal ['RtEsThing'], ivar(spawned, :@classes).box.items, 'accepting does not widen the list'
  end

  def test_spawned_class_browser_closes_when_its_class_is_removed
    make_thing
    GUI::Browser.open(RtEsThing).send(:spawn_class)
    spawned = GUI.windows.last
    spawned.send(:remove_class)
    refute defined?(RtEsThing)
    assert ivar(spawned, :@window).destroyed?, 'nothing is left to browse'
  end

  def test_spawn_class_on_a_builtin_and_the_normal_browser_is_unaffected
    browser = GUI::Browser.open(String)
    browser.send(:spawn_class)
    assert_equal ['String'], ivar(GUI.windows.last, :@classes).box.items
    refute ivar(browser, :@single)
    assert_includes ivar(browser, :@classes).box.items, 'Symbol', 'the normal browser still lists the whole category'
  end
end
