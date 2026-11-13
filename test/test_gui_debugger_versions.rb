# frozen_string_literal: true

# Debugger, hierarchy browser and Versions windows.
#   ruby test/test_gui_debugger_versions.rb

require_relative 'support/gui_case'

class GuiDebuggerVersionsTest < GuiCase
  def debugger_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtDbgW\nend\n", changes: changes)
    Compiler.accept("def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", klass: RtDbgW, changes: changes)
    GUI::Workspace.new(text: 'RtDbgW.new.explode(21)').editor.do_it
    GUI.windows.last
  end

  def versions_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtVw\nend\n", changes: changes)
    Compiler.accept("def v\n  1\nend\n", klass: RtVw, changes: changes)
    Compiler.accept("def v\n  2\nend\n", klass: RtVw, changes: changes)
  end

  # --- debugger ----------------------------------------------------------


  def test_debugger_shows_stack_source_locals_and_evaluates_in_the_frame
    debugger = debugger_fixture
    assert_instance_of GUI::Debugger, debugger
    assert_match(/rubytalk:RtDbgW:3/, ivar(debugger, :@stack).box.items.first)
    assert_equal "def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", debugger.source.contents
    assert_includes debugger.source.text.tag_command(['names', '3.0']).split, 'rt_current_line', 'the failing line is marked'
    refute_includes debugger.source.text.tag_command(['names', '1.0']).split, 'rt_current_line'

    rows = ivar(debugger, :@variables).box.items
    assert(rows.any? { |row| row.start_with?('local = 42') }, rows.inspect)
    assert(rows.any? { |row| row.start_with?('n = 21') })

    debugger.console.set_contents('local + 1')
    debugger.console.print_it
    assert_equal 'local + 1 43', debugger.console.contents, 'evaluated in the frame that raised'
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_outer_frames_have_source_but_no_locals
    debugger = debugger_fixture
    stack = ivar(debugger, :@stack)
    outer = stack.box.items.index { |item| item.include?('workspace:1') }
    refute_nil outer
    stack.box.click(outer)
    assert_equal "RtDbgW.new.explode(21)", debugger.source.contents
    assert_empty ivar(debugger, :@variables).box.items
    assert_match(/only kept for the frame that raised/, ivar(debugger, :@status).options[:text])
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_edit_method_opens_the_browser_on_it
    debugger = debugger_fixture
    debugger.send(:edit_method)
    browser = GUI.windows.last
    assert_instance_of GUI::Browser, browser
    assert_equal "def explode(n)\n  local = n * 2\n  raise 'boom'\nend\n", browser.code.contents
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_inspects_a_variable
    debugger = debugger_fixture
    variables = ivar(debugger, :@variables)
    index = variables.box.items.index { |row| row.start_with?('local = ') }
    variables.box.click(index)
    debugger.send(:inspect_variable)
    assert_instance_of GUI::Inspector, GUI.windows.last
    assert_equal 42, ivar(GUI.windows.last, :@object)
  ensure
    Object.send(:remove_const, :RtDbgW) if defined?(RtDbgW)
  end

  def test_debugger_run_again_after_a_fix
    $rt_flag = false
    editor = GUI::Workspace.new(text: "$rt_flag = !$rt_flag; raise 'first time' if $rt_flag; :fine").editor
    editor.do_it
    debugger = GUI.windows.last
    assert_instance_of GUI::Debugger, debugger
    debugger.send(:run_again)
    assert_match(/Run again: :fine/, Transcript.buffer)
  end

  def test_debugger_run_again_that_fails_again_opens_a_new_debugger
    $rt_runs = 0
    GUI::Workspace.new(text: "$rt_runs += 1; raise 'still broken'").editor.do_it
    first = GUI.windows.last
    first.send(:run_again)
    assert_equal 2, $rt_runs
    assert_instance_of GUI::Debugger, GUI.windows.last
    refute_same first, GUI.windows.last
  end

  def test_debugger_copes_with_an_error_that_has_no_stack
    debugger = GUI::Debugger.new(RuntimeError.new('no backtrace'))
    assert_match(/No stack is available/, debugger.source.contents)
    debugger.send(:edit_method) # nothing to edit: must not raise
    debugger.send(:run_again)
    assert_equal 'This cannot be run again.', ivar(debugger, :@status).options[:text]
  end

  # --- hierarchy ---------------------------------------------------------

  def test_hierarchy_browser_lists_the_hierarchy_and_works_like_a_browser
    Object.const_set(:RtHb1, Class.new)
    Object.const_set(:RtHb2, Class.new(RtHb1))
    browser = GUI::Browser.open(RtHb1, hierarchy: true)
    assert_equal ['Hierarchy of RtHb1'], ivar(browser, :@categories).box.items
    classes = ivar(browser, :@classes)
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2'], classes.box.items
    assert_equal "class RtHb1 < Object\nend\n", browser.code.contents, 'the class you asked about is selected'

    browser.code.set_contents("class RtHb3 < RtHb2\nend\n")
    browser.code.accept
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2', '        RtHb3'], classes.box.items,
                 'a new subclass joins the hierarchy and is selected'
    assert_match(/class RtHb3 < RtHb2/, browser.code.contents)

    ivar(classes, :@filter_var).value = +'hb2'
    browser.send(:refresh_classes)
    assert_equal ['      RtHb2'], classes.box.items, 'the filter box works on the hierarchy'
    ivar(classes, :@filter_var).value = +''
    browser.send(:refresh_classes)

    browser.send(:remove_class) # RtHb3 is still selected
    refute defined?(RtHb3)
    assert_equal ['BasicObject', '  Object', '    RtHb1', '      RtHb2'], classes.box.items
  ensure
    %i[RtHb3 RtHb2 RtHb1].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_hierarchy_opens_from_the_browser_and_from_an_editor
    browser = GUI::Browser.open(String)
    browser.send(:show_hierarchy)
    window = GUI.windows.last
    assert_equal String, ivar(window, :@hierarchy_root)
    assert_equal ['BasicObject', '  Object', '    String'], ivar(window, :@classes).box.items.first(3)

    GUI::Workspace.new(text: 'String').editor.hierarchy_of_it
    assert_equal String, ivar(GUI.windows.last, :@hierarchy_root)
    GUI::Workspace.new(text: '3').editor.hierarchy_of_it
    assert_equal Integer, ivar(GUI.windows.last, :@hierarchy_root), 'a non-class gives the hierarchy of its class'
  end

  def test_normal_browser_is_unaffected_by_hierarchy_mode
    browser = GUI::Browser.open(String)
    assert_nil ivar(browser, :@hierarchy_root)
    assert_includes ivar(browser, :@categories).box.items, 'Text'
    assert_includes ivar(browser, :@classes).box.items, 'String'
  end

  # --- versions ---------------------------------------------------------


  def test_versions_window_lists_shows_diffs_and_reverts
    versions_fixture
    changed = 0
    window = GUI::VersionsWindow.new(RtVw, :instance, 'v', on_change: -> { changed += 1 })
    list = ivar(window, :@list)
    assert_equal 2, list.box.items.size
    assert_match(/\ACurrent - /, list.box.items.first)
    assert_equal "def v\n  2\nend\n", window.code.contents, 'the newest version is selected first'

    list.box.click(1)
    assert_equal "def v\n  1\nend\n", window.code.contents

    ivar(window, :@diff_var).value = +'1'
    window.send(:show, list.selected_value)
    assert_equal "  def v\n-   2\n+   1\n  end\n", window.code.contents, 'shows what reverting would change'
    tags_at = ->(index) { window.code.text.tag_command(['names', index]).split }
    assert_includes tags_at.call('2.0'), 'rt_diff_del'
    assert_includes tags_at.call('3.0'), 'rt_diff_add'
    refute_includes tags_at.call('1.0'), 'rt_diff_add'

    window.send(:revert)
    assert_equal 1, RtVw.new.v
    assert_equal 1, changed
    assert_match(/def v/, window.code.contents)
    assert_equal 3, ivar(window, :@list).box.items.size, 'the replaced version joins the history'
  ensure
    Object.send(:remove_const, :RtVw) if defined?(RtVw)
  end

  def test_versions_window_with_nothing_to_show
    window = GUI::VersionsWindow.new(String, :instance, 'upcase')
    assert_empty ivar(window, :@list).box.items
    assert_match(/No earlier versions/, window.code.contents)
    window.send(:revert) # must not raise
  end

  def test_browser_opens_versions_and_remove_restores_the_original
    Object.const_set(:RtLibB, Class.new { def old = :old })
    browser = GUI::Browser.new(RtLibB)
    ivar(browser, :@protocols).box.click(0)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(:old))
    browser.code.set_contents("def old\n  :changed\nend\n")
    browser.code.accept
    assert_equal :changed, RtLibB.new.old

    browser.send(:show_versions)
    assert_instance_of GUI::VersionsWindow, GUI.windows.last
    assert_equal 2, ivar(GUI.windows.last, :@list).box.items.size, 'current + original'

    browser.send(:remove_method)
    assert_equal :old, RtLibB.new.old
    assert_equal 'Restored the original method.', ivar(browser, :@status).options[:text]
    assert_match(/def old/, browser.code.contents)

    browser.code.set_contents("class RtMineB\n  def mine; end\nend\n")
    browser.code.accept
    ivar(browser, :@protocols).box.click(0)
    methods = ivar(browser, :@methods)
    methods.box.click(ivar(methods, :@values).index(:mine))
    browser.send(:remove_method)
    refute RtMineB.method_defined?(:mine)
    assert_equal 'Method removed.', ivar(browser, :@status).options[:text]
  ensure
    %i[RtLibB RtMineB].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def test_method_list_opens_versions
    Compiler.accept("class RtMl2\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def v; 1; end\n", klass: RtMl2, changes: RubyTalk.changes)
    Compiler.accept("def v; 2; end\n", klass: RtMl2, changes: RubyTalk.changes)
    GUI.show_method_list(:implementors, 'v')
    list = GUI.windows.last
    index = ivar(list, :@hits).index { |hit| hit.label == 'RtMl2#v' }
    ivar(list, :@list).box.click(index)
    list.send(:versions)
    assert_instance_of GUI::VersionsWindow, GUI.windows.last
    assert_equal 2, ivar(GUI.windows.last, :@list).box.items.size
    ivar(GUI.windows.last, :@list).box.click(1) # the earlier version
    GUI.windows.last.send(:revert)
    assert_equal 1, RtMl2.new.v
    assert_equal "def v; 1; end\n", list.code.contents, 'the method list shows the reverted source'
  ensure
    Object.send(:remove_const, :RtMl2) if defined?(RtMl2)
  end
end
