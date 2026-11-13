# frozen_string_literal: true

# Start-up, Method List, Change Directory, highlighting, window layout, class comments.
#   ruby test/test_gui_windows.rb

require_relative 'support/gui_case'

class GuiWindowsTest < GuiCase
  def geometry_of(window)
    tk('wm', 'geometry', window.path).to_s
  end

  def set_geometry(window, spec)
    tk('wm', 'geometry', window.path, spec)
  end


  def test_tk_console_is_hidden_at_start_when_there_is_one
    Tk.console_present = true
    GUI.start
    assert_equal 'withdrawn', Tk.console_state, "Tk's Console window must not be left showing"
    assert_equal [GUI::MainWindow, GUI::Browser, GUI::Workspace], GUI.windows.last(3).map(&:class)
  ensure
    Tk.console_present = false
  end

  def test_no_console_is_fine
    Tk.console_present = false
    refute GUI.hide_tk_console, 'nothing to hide, and no error'
    GUI.start # must not raise
    Tk.console_present = true
    assert GUI.hide_tk_console
  ensure
    Tk.console_present = false
  end

  def test_start_opens_transcript_browser_and_workspace
    GUI.start
    assert_equal [GUI::MainWindow, GUI::Browser, GUI::Workspace], GUI.windows.last(3).map(&:class)
    assert GUI.icon_image, 'the window/Dock icon is set at startup'
  end

  def test_method_list_accept_recompiles_in_place
    Compiler.accept("class RtMl\nend\n", changes: RubyTalk.changes)
    Compiler.accept("def v\n  1\nend\n", klass: RtMl, changes: RubyTalk.changes)
    GUI.show_method_list(:implementors, 'v')
    list = GUI.windows.last
    assert_instance_of GUI::MethodList, list
    index = ivar(list, :@hits).index { |hit| hit.label == 'RtMl#v' }
    ivar(list, :@list).box.click(index)
    assert_equal "def v\n  1\nend\n", list.code.contents
    list.code.set_contents("def v\n  2\nend\n")
    list.code.accept
    assert_equal 2, RtMl.new.v
  ensure
    Object.send(:remove_const, :RtMl) if defined?(RtMl)
  end

  def test_change_directory_restarts_in_the_chosen_folder
    target = File.join(@dir, 'other')
    Tk.chooser_requests.clear
    assert_equal target, change_directory_with(target)
    assert File.directory?(target)
    assert_equal @dir, Tk.chooser_requests.last[1], 'the chooser starts in the current folder'
    assert_match(/Could not restart automatically/, Transcript.buffer, 'reported when the restart returns')
  end

  def test_change_directory_does_nothing_on_cancel_same_folder_or_decline
    assert_nil change_directory_with(''), 'Cancel'
    assert_nil change_directory_with(@dir), 'the folder already in use'
    other = File.join(@dir, 'declined')
    assert_nil change_directory_with(other, confirm: 'no')
    refute File.exist?(other)
  end

  def test_run_remembers_the_folder_for_next_time
    with_home(@dir) do
      folder = File.join(@dir, 'remembered')
      FileUtils.mkdir_p(folder)
      RubyTalk.run(dir: folder)
      assert_equal folder, Preferences.last_directory
      assert_equal File.join(folder, 'changes.rb'), RubyTalk.changes.path
    end
  end

  def test_code_panes_are_highlighted_and_the_transcript_is_not
    workspace = GUI::Workspace.new(text: "def foo; :sym; end # c")
    text = workspace.editor.text
    tags_at = ->(index) { text.tag_command(['names', index]).split }
    assert_includes tags_at.call('1.0'), 'rt_keyword'
    assert_includes tags_at.call('1.4'), 'rt_def_name'
    assert_includes tags_at.call('1.9'), 'rt_symbol'
    assert_includes tags_at.call('1.20'), 'rt_comment'

    workspace.editor.set_contents('x = 1')
    assert_includes tags_at.call('1.4'), 'rt_number'
    refute_includes tags_at.call('1.0'), 'rt_keyword', 'old colours are cleared'

    main = GUI::MainWindow.new
    main.editor.set_contents('def foo; end')
    assert_empty main.editor.text.tag_store, 'the Transcript is output, not code: no highlighting'
  end

  def test_highlighting_follows_typing_and_print_it
    editor = GUI::Workspace.new(text: '1 + 1').editor
    editor.print_it
    assert_includes editor.text.tag_command(['names', '1.0']).split, 'rt_number'
    editor.text.insert('end', +' # typed')
    editor.text.fire('KeyRelease')
    assert_includes editor.text.tag_command(['names', '1.8']).split, 'rt_comment'
  end

  def test_palette_follows_the_background_colour
    Tk.rgb_answer = '0 0 0'
    dark = GUI::Workspace.new(text: 'x').editor
    assert_equal RubyTalk::Highlighter::PALETTES[:dark][:keyword], dark.text.tag_options['rt_keyword']['-foreground']
    Tk.rgb_answer = '65535 65535 65535'
    light = GUI::Workspace.new(text: 'x').editor
    assert_equal RubyTalk::Highlighter::PALETTES[:light][:keyword], light.text.tag_options['rt_keyword']['-foreground']
  ensure
    Tk.rgb_answer = nil
  end

  # --- remembered window layout ---------------------------------------------------



  def test_windows_are_staggered_without_a_saved_layout
    first = GUI::Workspace.new(text: 'a').window
    second = GUI::Workspace.new(text: 'b').window
    refute_equal geometry_of(first), geometry_of(second)
  end

  def test_saved_layout_is_used_for_the_first_window_of_a_kind_and_nudged_for_the_next
    Preferences.save_layout(workspace: '500x400+100+120')
    first = GUI::Workspace.new(text: 'a').window
    second = GUI::Workspace.new(text: 'b').window
    assert_equal '500x400+100+120', geometry_of(first)
    assert_equal '500x400+128+148', geometry_of(second), 'a second window of the kind is nudged'
    browser = GUI::Browser.new
    assert_match(/\A100x100\+\d+\+\d+\z/, geometry_of(ivar(browser, :@window)), 'a kind with no saved layout is staggered')
  end

  def test_saved_geometry_is_kept_on_screen
    Tk.screen_width = 1000
    Tk.screen_height = 700
    Preferences.save_layout(workspace: '3000x2000+5000+900', browser: '400x300-900-50')
    assert_equal '960x620+900+640', geometry_of(GUI::Workspace.new(text: 'a').window), 'smaller than the screen, a corner showing'
    assert_equal '400x300-300+0', geometry_of(ivar(GUI::Browser.new, :@window)), 'no more than all but 100 pixels off the left'
  end

  def test_layout_is_saved_on_quit_one_entry_per_kind_from_the_newest_window
    first = GUI::Workspace.new(text: 'a').window
    set_geometry(first, '300x200+10+10')
    second = GUI::Workspace.new(text: 'b').window
    set_geometry(second, '640x480+50+60')
    GUI::MainWindow.new
    GUI.quit
    layout = Preferences.layout
    assert_equal '640x480+50+60', layout['workspace']
    assert layout.key?('transcript')
  end

  def test_closing_a_window_remembers_where_it_was
    window = GUI::Workspace.new(text: 'a').window
    set_geometry(window, '321x234+11+22')
    window.protocols['WM_DELETE_WINDOW'].call
    assert window.destroyed?
    GUI.save_layout
    assert_equal '321x234+11+22', Preferences.layout['workspace'], 'kept although no window of that kind is open now'
  end

  def test_the_transcript_keeps_its_quit_handler
    main = GUI::MainWindow.new
    quit_called = false
    GUI.stub(:quit, -> { quit_called = true }) { main.root.protocols['WM_DELETE_WINDOW'].call }
    assert quit_called, 'closing the Transcript quits; it is not just another window'
  end

  def test_change_directory_saves_the_layout_first
    set_geometry(GUI::Workspace.new(text: 'a').window, '700x500+30+40')
    change_directory_with(File.join(@dir, 'elsewhere'))
    assert_equal '700x500+30+40', Preferences.layout['workspace']
  end

  def test_a_failing_layout_save_does_not_stop_quitting
    ENV['HOME'] = '/nonexistent-home-for-rubytalk'
    GUI::Workspace.new(text: 'a')
    GUI.quit # must not raise
    assert Tk.root.destroyed?
  end

  # --- class comments ----------------------------------------------------

  def test_browser_shows_and_edits_class_comments
    Object.const_set(:RtCommented, Class.new)
    browser = GUI::Browser.open(RtCommented)
    assert_equal "class RtCommented < Object\nend\n", browser.code.contents, 'no comment yet'
    browser.code.set_contents("# Says hello.\nclass RtCommented < Object\nend\n")
    browser.code.accept
    assert_equal "# Says hello.\nclass RtCommented < Object\nend\n", browser.code.contents
    again = GUI::Browser.open(RtCommented)
    assert_equal "# Says hello.\nclass RtCommented < Object\nend\n", again.code.contents, 'a new browser shows it too'
    tags = again.code.text.tag_command(['names', '1.2']).split
    assert_includes tags, 'rt_comment'
  ensure
    Object.send(:remove_const, :RtCommented) if defined?(RtCommented)
  end
end
