# NOTE: no frozen_string_literal here: the tk gem mutates (force_encoding) strings it is given.

module RubyTalk
  module GUI
    class SelfTest
      # Checks of the Browser and the windows built on it: Inspector, Method List, Versions, Debugger, tests, file out and in.
      # Uses the helpers of SelfTest (update, generate, click, assert ...).
      module BrowserChecks
        def check_inspector
          editor = Workspace.new(text: '[10, 20, {a: 1}]').editor
          editor.inspect_it
          inspector = GUI.windows.last
          assert(inspector.is_a?(Inspector), 'no inspector opened')
          list = ivar(inspector, :@list)
          assert_equal 4, list_size(list)
          click(list, 1)
          assert_equal '10', ivar(inspector, :@value).contents
        end

        def check_browser_navigation
          browser = Browser.open(String)
          assert(browser.code.contents.start_with?('class String'), 'class definition not shown')
          protocols = ivar(browser, :@protocols)
          assert_equal 4, list_size(protocols)
          click(protocols, 1)
          methods = ivar(browser, :@methods)
          assert(list_size(methods) > 50, 'method list did not fill')
          click_value(methods, :upcase)
          assert(browser.code.contents.include?('implemented in C'), 'method description not shown')
          generate(ivar(browser, :@classes).box, '<KeyRelease>') # must not raise
        end

        def check_browser_accept_and_autosave
          browser = Browser.open
          categories = ivar(browser, :@categories)
          click_value(categories, Reflection::USER)
          assert_equal Reflection.new_class_template, browser.code.contents
          browser.code.set_contents("class RtSelfTest\nend\n")
          browser.code.accept
          assert(defined?(::RtSelfTest), 'class was not created')
          click(ivar(browser, :@protocols), 0)
          browser.code.set_contents("def hi\n  rt_selftest_marker\nend\n")
          browser.code.accept
          assert(::RtSelfTest.method_defined?(:hi), 'method was not defined')
          assert_equal "def hi\n  rt_selftest_marker\nend\n", browser.code.contents
          text = File.read(changes_path)
          assert(text.include?('target=RtSelfTest') && text.include?('key=hi'), 'autosave did not write changes.rb')
        end

        def check_browser_accept_by_key
          browser = Browser.open(::RtSelfTest)
          click(ivar(browser, :@protocols), 0)
          browser.code.set_contents("def other\n  :other\nend\n")
          browser.code.focus
          update
          generate(browser.code.text, "<#{MODIFIER}-Key-s>")
          assert_equal :other, ::RtSelfTest.new.other
        end

        def check_search_implementors_and_senders
          assert(Search.implementors('upcase').any? { |hit| hit.klass == String }, 'String#upcase not found')
          senders = Search.senders('rt_selftest_marker')
          assert(senders.any? { |hit| hit.label == 'RtSelfTest#hi' }, "senders: #{senders.map(&:label).inspect}")
        end

        def check_method_list_window
          GUI.show_method_list(:implementors, 'upcase')
          window = GUI.windows.last
          assert(window.is_a?(MethodList), 'no method list opened')
          click(ivar(window, :@list), 0)
          assert(window.code.contents.include?('upcase'), 'method source not shown')
        end

        def check_implementors_key_binding
          editor = Workspace.new(text: 'upcase').editor
          editor.text.tag_add('sel', '1.0', '1.end')
          editor.focus
          update
          generate(editor.text, "<#{MODIFIER}-Key-m>")
          assert(GUI.windows.last.is_a?(MethodList), 'Cmd-M did not open a method list')
        end

        # Spawn copies a method (with unaccepted edits) into a window of its own that still accepts in place.
        def check_spawn_method_window
          browser = Browser.open(::RtSelfTest, method: :other)
          browser.code.set_contents("def other\n  :spawned\nend\n")
          browser.code.spawn
          window = GUI.windows.last
          assert(window.is_a?(MethodList), 'Spawn did not open a method window')
          assert_equal "def other\n  :spawned\nend\n", window.code.contents
          window.code.accept
          assert_equal :spawned, ::RtSelfTest.new.other
          Browser.open(::RtSelfTest).send(:spawn_class)
          assert(GUI.windows.last.is_a?(Browser), 'Spawn class did not open a browser')
        end

        # A `# protocol: name` comment files a method under a protocol of your own; a class definition
        # has versions like a method does.
        def check_protocols_and_class_versions
          browser = Browser.open(::RtSelfTest)
          protocols = ivar(browser, :@protocols)
          click(protocols, 0)
          browser.code.set_contents("# protocol: selftest\ndef proto\n  1\nend\n")
          browser.code.accept
          assert(ivar(protocols, :@values).include?('selftest'), "protocols: #{ivar(protocols, :@values).inspect}")
          click_value(protocols, 'selftest')
          assert(ivar(ivar(browser, :@methods), :@values).include?(:proto), 'the protocol does not list its method')
          assert(Reflection.versions(::RtSelfTest, :instance, nil).any? { |v| v.kind == :current }, 'no class version')
        end

        # Replays what this run wrote into a fresh ChangeSet, in this process.
        def check_changes_file_replays
          entries = ChangeSet.parse(File.read(changes_path)).compact
          assert(entries.any? { |e| e.kind == :class && e.target == 'RtSelfTest' }, 'class entry missing')
          assert(entries.any? { |e| e.kind == :method && e.key == 'other' }, 'method entry missing')
        end

        # Redefine a method twice, then open its Versions window: the list, the selected
        # version's text and a revert, with real widgets.
        def check_versions_window
          klass = ::RtSelfTest
          changes = RubyTalk.changes
          Compiler.accept("def hi\n  :v2\nend\n", klass: klass, changes: changes)
          Compiler.accept("def hi\n  :v3\nend\n", klass: klass, changes: changes)
          window = VersionsWindow.new(klass, :instance, 'hi')
          list = ivar(window, :@list)
          assert(list_size(list) >= 3, "expected current + two earlier versions, got #{list_size(list)}")
          click(list, 1)
          assert(window.code.contents.include?(':v2'), "the newest earlier version was not shown: #{window.code.contents.inspect}")
          window.send(:revert)
          assert_equal :v2, klass.new.hi
        end

        # Hierarchy mode of the browser, with real widgets: the list starts at BasicObject.
        def check_hierarchy_browser
          browser = Browser.open(::RtSelfTest, hierarchy: true)
          classes = ivar(browser, :@classes)
          assert(list_size(classes) >= 3, "expected BasicObject, Object, RtSelfTest; got #{list_size(classes)} rows")
          assert_equal 'BasicObject', Tk.tk_call(classes.box.path, 'get', 0).to_s
          assert(browser.code.contents.start_with?('class RtSelfTest'), 'the class was not selected')
        end

        # An error opens the debugger with the locals of the frame that raised, and the console
        # evaluates in that frame (a binding captured by TracePoint at the raise, kept alive
        # after the stack unwound).
        def check_debugger
          Workspace.new(text: 'dbg_value = 41; raise "selftest debugger"').editor.do_it
          debugger = GUI.windows.last
          assert(debugger.is_a?(Debugger), 'no debugger opened')
          variables = ivar(debugger, :@variables)
          rows = Array.new(list_size(variables)) { |i| Tk.tk_call(variables.box.path, 'get', i).to_s }
          assert(rows.any? { |row| row.start_with?('dbg_value = 41') }, "locals shown: #{rows.inspect}")
          debugger.console.set_contents('dbg_value + 1')
          debugger.console.print_it
          assert_equal 'dbg_value + 1 42', debugger.console.contents
        end

        # Edit the comment above a class that already existed, accept, and reopen the browser.
        def check_class_comment
          Object.const_set(:RtSelfDoc, Class.new)
          browser = Browser.open(::RtSelfDoc)
          browser.code.set_contents("# selftest doc\nclass RtSelfDoc < Object\nend\n")
          browser.code.accept
          assert_equal "# selftest doc\n", Reflection.class_comment(::RtSelfDoc)
          again = Browser.open(::RtSelfDoc)
          assert(again.code.contents.start_with?("# selftest doc\n"), 'a new browser did not show the comment')
        ensure
          Object.send(:remove_const, :RtSelfDoc) if Object.const_defined?(:RtSelfDoc)
        end

        # Define a class with a passing and a failing Minitest test, run them from the class (on the
        # worker thread, through real Minitest) and look at the results window.
        def check_test_runner
          changes = RubyTalk.changes
          TestRunner.load_minitest
          Compiler.accept("class RtSelfCalc\nend\n", changes: changes)
          Compiler.accept("class RtSelfCalcTest < Minitest::Test\nend\n", changes: changes)
          Compiler.accept("def test_passes\n  assert true\nend\n", klass: ::RtSelfCalcTest, changes: changes)
          Compiler.accept("def test_fails\n  assert_equal 1, 2\nend\n", klass: ::RtSelfCalcTest, changes: changes)
          GUI.run_tests_for(::RtSelfCalc)
          window = GUI.windows.last
          assert(window.is_a?(TestResultsWindow), 'no results window opened')
          assert_equal 2, list_size(ivar(window, :@list))
          bar = ivar(window, :@bar)
          assert_equal '1 of 2 tests failed', Tk.tk_call(bar.path, 'cget', '-text').to_s
        ensure
          %i[RtSelfCalcTest RtSelfCalc].each do |name|
            next unless Object.const_defined?(name)

            TestRunner.forget(Object.const_get(name))
            Object.send(:remove_const, name)
          end
        end

        # File a class out to plain Ruby, remove it, file the file back in: the class and its method return and
        # are recorded again. (The dialogs need a person; this uses explicit paths.)
        def check_file_out_and_in
          changes = RubyTalk.changes
          Compiler.accept("# Filed out in the self-test.\nclass RtSelfEx\nend\n", changes: changes)
          Compiler.accept("def hello\n  :hello\nend\n", klass: ::RtSelfEx, changes: changes)
          path = File.join(File.dirname(changes.path), 'rt_self_ex.rb')
          GUI.file_out_class(::RtSelfEx, path)
          text = File.read(path)
          assert(Source.syntax_error(text).nil?, 'the filed-out file is not valid Ruby')
          assert(text.include?('def hello'), 'the method is missing from the file')
          Compiler.remove_class(::RtSelfEx, changes)
          assert(!Object.const_defined?(:RtSelfEx), 'the class should be gone')
          summary = GUI.file_in(path)
          assert(summary&.ok?, "file in failed: #{summary&.errors.inspect}")
          assert_equal :hello, ::RtSelfEx.new.hello
          assert(changes.find_method('RtSelfEx', :instance, 'hello'), 'the method was not recorded as a change')
        ensure
          Object.send(:remove_const, :RtSelfEx) if Object.const_defined?(:RtSelfEx)
        end
      end

      include BrowserChecks
    end
  end
end
