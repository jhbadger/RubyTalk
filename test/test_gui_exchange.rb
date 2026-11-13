# frozen_string_literal: true

# File out and file in from the windows.
#   ruby test/test_gui_exchange.rb

require_relative 'support/gui_case'

class GuiExchangeTest < GuiCase
  def filed_fixture
    changes = RubyTalk.changes
    Compiler.accept("class RtGx\nend\n", changes: changes)
    Compiler.accept("def hello\n  :hello\nend\n", klass: RtGx, changes: changes)
    Compiler.accept("class RtGy\nend\n", changes: changes)
  end

  def drop_filed_fixture
    %i[RtGx RtGy RtFiled].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
    Tk.dialog_answer = nil
  end

  # --- file out and file in ---------------------------------------------------------



  def test_file_out_class_writes_plain_ruby_to_the_chosen_file
    filed_fixture
    path = File.join(@dir, 'rt_gx.rb')
    Tk.dialog_answer = path
    GUI.file_out_class(RtGx)
    text = File.read(path)
    assert_includes text, 'def hello'
    refute_includes text, 'RtGy', 'only that class'
    assert_nil RubyTalk::Source.syntax_error(text)
    assert_match(/Filed out RtGx to #{Regexp.escape(path)}/, Transcript.buffer)
    request = Tk.dialog_requests.last
    assert_equal 'rt_gx.rb', request[request.index('-initialfile') + 1]
    assert_equal @dir, request[request.index('-initialdir') + 1], 'the dialog starts in the image folder'
  ensure
    drop_filed_fixture
  end

  def test_file_out_names_the_default_file_in_snake_case
    Compiler.accept("class RtFiled\nend\n", changes: RubyTalk.changes)
    Compiler.accept("class RtFiled::SomeThing\nend\n", changes: RubyTalk.changes)
    Tk.dialog_answer = ''
    GUI.file_out_class(RtFiled::SomeThing)
    request = Tk.dialog_requests.last
    assert_equal 'rt_filed_some_thing.rb', request[request.index('-initialfile') + 1]
  ensure
    drop_filed_fixture
  end

  def test_file_out_cancelled_nothing_to_file_out_and_unwritable
    filed_fixture
    Tk.dialog_answer = ''
    GUI.file_out_class(RtGx)
    GUI.file_out_changes
    refute Dir.glob(File.join(@dir, '*.rb')).any? { |file| File.basename(file) != 'changes.rb' }, 'Cancel writes nothing'

    GUI.file_out_class(Comparable)
    assert_match(/Nothing to file out: Comparable has no recorded changes/, Transcript.buffer)

    Tk.dialog_answer = '/nonexistent-dir-for-rubytalk/out.rb'
    GUI.file_out_class(RtGx) # must not raise
    assert_match(/Could not write/, Transcript.buffer)
  ensure
    drop_filed_fixture
  end

  def test_file_out_changes_writes_everything
    filed_fixture
    path = File.join(@dir, 'all.rb')
    Tk.dialog_answer = path
    GUI.file_out_changes
    text = File.read(path)
    assert_includes text, 'class RtGy'
    assert_includes text, 'def hello'
  ensure
    drop_filed_fixture
  end

  def test_file_in_reports_what_it_did
    path = File.join(@dir, 'in.rb')
    File.write(path, "class RtFiled\n  def a\n    1\n  end\n\n  def b\n    2\n  end\nend\n\nraise 'trouble'\n")
    Tk.dialog_answer = path
    summary = GUI.file_in
    assert_equal [1, 2, 1], [summary.classes, summary.methods, summary.errors.size]
    assert_equal 3, RtFiled.new.a + RtFiled.new.b
    assert_match(/Filed in in\.rb: 1 class created, 2 methods, 0 other class statements, 0 top-level statements run; 1 error/, Transcript.buffer)
    assert_match(/trouble/, Transcript.buffer)
    assert_equal 'in.rb', File.basename(path)
    request = Tk.dialog_requests.last
    assert_equal @dir, request[request.index('-initialdir') + 1]
  ensure
    drop_filed_fixture
  end

  def test_file_in_cancelled_and_unreadable
    Tk.dialog_answer = ''
    assert_nil GUI.file_in
    assert_nil GUI.file_in('/nonexistent-file-for-rubytalk.rb')
    assert_match(/Could not read/, Transcript.buffer)
  end

  def test_system_menu_and_class_menu_offer_file_out_and_in
    menubar = GUI::Workspace.new(text: 'x').window.options[:menu]
    system_menu = menubar.entries.first[1][:menu]
    labels = system_menu.entries.map { |_, options| options[:label] }
    assert_includes labels, 'File In...'
    assert_includes labels, 'File Out Changes as Ruby...'

    path = File.join(@dir, 'menu.rb')
    File.write(path, "class RtFiled\n  def z\n    :z\n  end\nend\n")
    Tk.dialog_answer = path
    system_menu.invoke('File In...')
    assert_equal :z, RtFiled.new.z

    filed_fixture
    Tk.dialog_answer = File.join(@dir, 'from_browser.rb')
    GUI::Browser.open(RtGx).send(:file_out_class)
    assert File.file?(File.join(@dir, 'from_browser.rb'))
  ensure
    drop_filed_fixture
  end
end
