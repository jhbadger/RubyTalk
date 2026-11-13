# RubyTalk

A Smalltalk-80 style programming environment for Ruby, built on Ruby/Tk.

## Run

```
gem install tk            # needs Tcl/Tk; on macOS: brew install tcl-tk
cd ~/some/project         # RubyTalk looks for ./changes.rb here
ruby ~/lib/src/rubytalk/bin/rubytalk (or put the file on your path)
```

Run it as a script, not from `irb` (Ruby/Tk crashed inside irb on macOS in testing).

The Transcript, a System Browser and a Workspace open at startup.

**First time on a new machine: run the self-test.** It drives the real windows with real
Tk (typing, selecting, key and mouse events, menu invocations) in a temporary directory,
prints PASS/FAIL per check, and exits non-zero on any failure. It never touches your
`changes.rb`.

```
ruby ~/lib/src/rubytalk/bin/rubytalk --selftest
```

When a check fails it also prints the last few Transcript lines, which usually hold the real reason (an error
the check itself could not see). It cannot test things that need a person (pop-up menus, how colours look, quitting cleanly).

## macOS app and icon

RubyTalk draws its own icon in code (a ruby gem in a speech bubble; no image files) and can
build a double-clickable application bundle with it, like the Python/Tk `--build-app` pattern.

```
ruby bin/rubytalk --build-app ~/Applications      # builds ~/Applications/RubyTalk.app
ruby bin/rubytalk --build-app . --link            # run the code in place (see below)
ruby bin/rubytalk --build-app . --workdir ~/smalltalk-image   # always use that folder, never ask
ruby bin/rubytalk --icon-png 512 icon.png         # just the icon, any size
```

* **Which folder holds `changes.rb`?** Finder starts apps in `/`, so the app is started with
  `--last-dir`: it opens in the folder RubyTalk was last run in, and your home directory the
  very first time. The choice is remembered in `~/Library/Application Support/RubyTalk/last_dir`
  (`~/.config/rubytalk/last_dir` on Linux) every time RubyTalk starts. **System > Change
  Directory...** picks another folder and restarts RubyTalk there (the classes from one folder's
  `changes.rb` cannot be unloaded from a running session, so a restart is the clean way to
  switch; everything accepted so far is already saved). Different folders are different images,
  each with its own `changes.rb`. Build with `--workdir DIR` to pin the app to one folder.
  From a terminal, `rubytalk` uses the current directory, `rubytalk --dir DIR` a folder you
  name, and `rubytalk --last-dir` the remembered one.
* **Which image am I in?** The Transcript window's title is `RubyTalk: <folder>`, and its first
  lines name the changes file, the working directory and where the code is running from.
  On macOS, System > Reveal Changes File in Finder opens the folder.
* **Copy or link?** By default the code is copied into the app, so it keeps working if you move
  or edit the source folder (rebuild to pick up changes). With `--link` the app runs the source
  where it is, so edits take effect on the next launch; it breaks if the folder moves.
  Either way, "where the code runs from" is shown in the Transcript banner.
* The launcher runs the Ruby that built it. For Homebrew Ruby it uses the stable
  `/opt/homebrew/opt/ruby/bin/ruby` path, so `brew upgrade ruby` does not break the app.
  If you switch Ruby versions or install the `tk` gem into a different Ruby, rebuild the app.
* The same icon is used for the windows (and the Dock when started from a terminal).
* Known limit: the launcher `exec`s Ruby, so macOS may show "ruby" as the app-menu title even
  though the Dock icon and name are RubyTalk's.
* An app you build yourself carries no quarantine flag, so it opens normally. If you copy one to
  another Mac by download or AirDrop, use right-click > Open the first time (it is not signed).

## Install as a gem, and develop

```
gem build rubytalk.gemspec && gem install rubytalk-0.2.0.gem   # puts `rubytalk` on your path (needs Tcl/Tk: see Run)
bundle install               # development tools only; the tk gem is optional (see the Gemfile)
rake test                    # every test file, each in its own process (no display or Tcl/Tk needed)
rake selftest                # the real windows with real Tk
rake rubocop                 # style (config in .rubocop.yml)
rake build                   # the gem, into pkg/
```

GitHub Actions (`.github/workflows/ci.yml`) runs `rake test` on Ruby 3.0 to 3.4 on Linux and macOS and
checks that the gem builds. The style check and `--selftest` (real Tk under a virtual display) run as
separate jobs that report but do not fail the build.

## The windows

**Transcript** (the main window). Output area and editor in one, as in Smalltalk.
`Transcript.show 'x'`, `show_cr`, `cr`, `tab`, `space`, `display`, `display_nl`,
`print_string(obj)`, `clear` write to it (camelCase aliases `showCr`, `displayNl`,
`nextPutAll` also exist). While code runs from a window, `$stdout`/`$stderr` point at the
Transcript, so `puts`, `p` and `warn` appear there too. Closing this window quits.

**Workspace** (System > Open Workspace). Free-form editor. Variables you assign stay
available to later evaluations in the same workspace.

| Command    | Mac      | Other    | What it does                                           |
|------------|----------|----------|--------------------------------------------------------|
| Do it      | Cmd-D    | Ctrl-D   | evaluate the selection (or current line)               |
| Print it   | Cmd-P    | Ctrl-P   | evaluate, insert `inspect` of the result, select it    |
| Inspect it | Cmd-I    | Ctrl-I   | evaluate, open an Inspector on the result              |
| Browse it  | Cmd-B    | Ctrl-B   | evaluate, open the Browser on the result's class       |
| Implementors of it | Cmd-M | Ctrl-M | selection (or word at cursor) as a method name: who defines it |
| Senders of it | Cmd-N | Ctrl-N   | selection (or word at cursor) as a method name: who calls it |
| Explain it | Cmd-E    | Ctrl-E   | selection (or word at cursor): what it is, in the Transcript (nothing is run) |
| Accept     | Cmd-S    | Ctrl-S   | (Browser code pane) compile and log the code           |
| Stop       | Cmd-.    | Ctrl-.   | interrupt the running do it (also System > Interrupt Running Code) |

These work in every text pane (Transcript, Workspace, Browser, Inspector) and from the
right-click menu. An error in a do it opens an error window (message + backtrace, with
"Inspect exception") and is also written to the Transcript.

**System Browser** (System > Open System Browser): category | class | protocol | method,
with a code pane underneath. Radio buttons choose instance or class side; "show inherited"
adds inherited methods; the box above the class list filters by name; `*` marks methods
changed through RubyTalk.

* Pick a category: the pane shows a template for a new class. Edit and Accept to create it.
  (Categories: User-Defined first, then Kernel-Objects, Numbers, Text, Collections, ...,
  and All Classes.)
* Pick a class: its definition. Pick a protocol (public/protected/private/all): a method
  template. Pick a method: its source (from the file it was defined in, from changes.rb,
  or, for C methods, a description plus a commented skeleton you can uncomment to override).
* Accept evaluates the pane. A `class`/`module` definition is defined at top level;
  `def` and `def self.` define methods on the selected class and side; any other statement
  (`attr_accessor`, `include`, ...) runs in the class body. Built-in classes can be extended
  this way. Right-click: New subclass, Remove class, Remove method.

**Running code and Stop.** A do it runs on a worker thread while the windows stay alive, so a
runaway `loop {}` cannot freeze RubyTalk: press **Cmd-.** (System > Interrupt Running Code) and the
code raises `RubyTalk::Evaluator::Interrupted`. That is deliberately not a `StandardError`, so a
plain `rescue => e` in your code cannot swallow it, and `ensure` blocks still run. If the code
catches everything (`rescue Exception`) and carries on, press Stop again within 3 seconds and the
thread is killed. Ctrl-C in the terminal that started RubyTalk does the same as Stop. The
Transcript's title bar says "running" while code runs; a second do it is refused until the first
ends; quitting while code runs stops it. Code that does heavy work inside a single C call (a huge
integer power, say) cannot be interrupted until that call returns. Tk itself must only be used from
the main thread, so output from your code's threads and windows your code opens
(`RubyTalk::GUI::Inspector.new(x)` inside a do it) are handed over to the main thread automatically;
code that calls Tk directly from a do it is on its own.

**Implementors and senders** open a Method List: the matching methods on top, the selected
method's source below (editable; Accept recompiles it where it lives). Double-click, or
right-click > Browse, to open the System Browser on it. Also in the Browser's method list
right-click menu.

* *Implementors* are exact: every class (instance or class side) that defines the name.
* *Senders* are approximate. Ruby's lexer finds uses of the name in the source of every
  method defined in a readable Ruby file, and in everything recorded in `changes.rb`.
  Comments and strings do not count, `def name` does not count, `:name` and `&:name` do.
  A local variable with the same name also matches, calls made through `send` with a
  computed name are invisible, methods built by `define_method` are found only if their
  source can be read, and `[]`/`[]=` are not searched.
  What each method uses is remembered after the first search, so repeating a search (or searching for
  another name) is several times faster; nothing needs refreshing: a file you edit, or a method you
  Accept, is simply looked at again.

**Explain it** (Cmd-E, Edit > Explain it, or the right-click menu) says what a word is, without running
anything. Select a word, or just put the cursor in it, and the answer is written to the Transcript. It
works through the same questions Squeak's explain does, in this order:

* a keyword (`self`, `nil`, `yield` ...): what it means;
* a **local variable or parameter**: where the code in that pane declares it ("amount is a parameter of method
  deposit (line 1)"). A call in a default value (`def m(a, b = helper)`) is not mistaken for a parameter;
* an **`@instance variable`**: which methods of the browser's selected class use it (comments and strings
  do not count), and whether a reader or writer method exists. With no class in view it says what the word is;
* a `@@class variable` or `$global`: its current value;
* a **Constant**: the class or module (superclass, mixins, method counts, source file, first line of its
  comment, and whether you created it in RubyTalk); `Foo::Bar` works too;
* a `:symbol`: says so, then explains the name as a selector;
* anything else is a **message selector**: if the class in view has such a method, its owner, visibility,
  arity and source location, then the classes that implement it (the first 12; Implementors of it lists all).

Which class is "in view" comes from the pane: the Browser's selected class and side, or the selected entry in a
Method List. Workspaces and the Inspector have none, so instance variables and selectors are explained in
general terms there. Locals are found by parsing the pane's text with Ripper, so they work in a Workspace too.

**Spawn** copies what you are looking at into a window of its own, as in Smalltalk-80.

* In any code pane (Edit > Spawn, or right-click > Spawn): with text selected, the selection goes into a new
  Workspace; with nothing selected, the whole pane is spawned. In the Browser and a Method List, a spawned
  method opens in its own method window (a Method List with a single entry) and keeps **unaccepted edits**:
  Accept there recompiles the method where it lives. The original pane is put back to the stored source, so
  the edits exist in exactly one place. A class definition or a new-method template goes to a Workspace.
* Browser method list, right-click > **Spawn method**; Method List, right-click > **Spawn**.
* Browser class list, right-click > **Spawn class**: a new Browser holding only that class (the class list
  is just the one class), for working on one class without the rest of the system in the way. Removing the
  class closes that window.

**Debugger.** When a do it raises an error, a Debugger window opens (instead of a plain backtrace):
the stack on the top left, the code of the selected frame on the top right with its current line
marked, `self` and the locals of the frame that raised on the bottom left (double-click one to
inspect it), and a console on the bottom right that evaluates **in that frame** (select text, then
Cmd-D / Cmd-P / Cmd-I), so `local + 1` or `self.class` answer about the moment of the error.
**Edit Method** (or double-click a frame) opens the browser on the failing method so you can fix it
and Accept; **Run Again** then evaluates the original do it again. It cannot resume where the error
happened: the stack has already unwound, so "fix and re-run" replaces "fix and proceed".
How it works: while code runs, a `TracePoint` records the binding at every `raise`; a Binding keeps its
locals alive after the stack unwinds. **Limits:** only the frame that raised has locals (Ruby keeps no
bindings for the others, which show source only); errors raised and rescued inside your code are
recorded too (the last 100), which costs a little in code that raises very many exceptions (about
9 times slower in a loop that does nothing else). `RubyTalk::Evaluator.max_records = 20` keeps fewer, and
`= 0` turns recording off altogether (no TracePoint is set up; the Debugger then shows the backtrace and the
source but no variables). Recording only happens while a do it is running.

**Class comments.** The comment block directly above `class Foo` is the class comment, shown at the top
of the definition pane. Edit it and Accept. For a class you created it is part of its definition. For
a class that already existed, RubyTalk keeps your comment in `changes.rb` as a small replayable entry
(the comment above the unchanged definition); for a library class written in Ruby the original RDoc
comment from its source file is shown until you change it. Clear the comment (or put the original back)
to return to the original. A new class starts from a template with a `# Describe NewClass here.` line.

**Tests.** Tests are ordinary Minitest classes made in the browser (`Minitest` is loaded for you; class list
right-click > **New test class** starts `class FooTest < Minitest::Test` with a first test). Right-click a
class > **Run tests** runs `FooTest`, `TestFoo` or `FooSpec` for it (or the class itself if it is a test
class); right-click a `test_...` method > **Run this test**; **System > Run All User Tests** runs every test
class you created. A results window shows a green or red bar, every test (errors and failures first, then
skips, then passes) with the message and location of the one you select, **Run Again**, **Run Failures**
(only the tests that failed: fix them in the browser, press it, watch the bar turn green) and **Edit
Test** (or double-click) to open the test. Tests run on the worker thread like any do it, so Cmd-. stops a
slow one, and anything they print appears in the Transcript. Minitest is driven directly, not through
`Minitest.run` or autorun, so nothing runs at exit. It works with Minitest 5 and 6 (6 renamed its running
methods, so RubyTalk lists a class's test methods itself and runs them one at a time). If the `minitest` gem is
missing you are told so.

**Find and replace.** **Cmd-F** (Ctrl-F elsewhere) opens a bar under the pane you are in (any pane,
including the Transcript); the selected text, if it is one line, fills the Find box. Typing marks every match
and selects the first from the cursor; **Return** or **Cmd-G** goes to the next, **Shift-Return** or
**Cmd-Shift-G** to the previous, wrapping round (the status says "wrapped"). **Match case** and **Regexp** change
how the pattern is read; in a regular expression `\1` .. `\9`, `\0` and `\&` in the Replace box stand for
groups of the match. **Replace** replaces the selected match and moves to the next (with none selected it
just finds one); **Replace All** does every match as a single undo step. **Escape** closes the bar. Positions
are counted in characters, so text with accents or emoji is marked correctly. At most 1000 matches are
coloured, though all are counted and replaced.

**Auto-indent and bracket matching** (code panes: Workspace, Browser, Method List, Versions, Debugger,
Inspector; not the Transcript). **Return** starts the next line at the indentation the last one calls for: the
same, plus two spaces after `def`, `class`, `module`, `if`/`unless`/`while`/`until`/`case`/`begin`/`for`,
`do`, an open `{` `(` `[`, or an `else`/`elsif`/`when`/`in`/`rescue`/`ensure` clause (a one-line
`def a; end`, an endless `def a = 1`, a modifier `puts 1 if x` and keywords inside strings and comments do not
count). **Tab** inserts two spaces. Typing `end`, `else`, `elsif`, `when`, `in`, `rescue`, `ensure` or a closing
`}` `]` `)` at the start of a line moves it back to line up with what it closes, but only when it sits at the
indentation auto-indent gave it, so existing code you click through is never rewritten. The bracket next to
the cursor is highlighted together with its partner (brackets inside strings, comments, symbols and regexps
do not count). It is a heuristic built on Ruby's lexer, not a parser: it favours predictable behaviour.

**Window layout.** Each kind of window (Transcript, Browser, Workspace, Inspector, Method List, Versions,
Debugger, test results) remembers its size and position and reopens there next time. It is saved when you
quit, when you switch directory, and when you close a window with its close button; a second window of the
same kind opens nudged down and right so they do not coincide. A saved position is clamped to the current
screen (smaller than the screen, at least 100 pixels visible), so unplugging a monitor never loses a window.
The layout is per user, not per folder: it lives next to `last_dir` (`~/Library/Application
Support/RubyTalk/layout` on macOS, `~/.config/rubytalk/layout` elsewhere) as lines like
`browser 900x600+80+90`; delete the file to start afresh. Windows closed with their own Close button (the
Debugger, results windows) are not remembered at that moment, only at quit if still open.

**File out and file in.** Move code between RubyTalk and ordinary `.rb` files.
**System > File Out Changes as Ruby...** writes everything recorded in `changes.rb` as plain, readable Ruby:
classes first, their methods grouped under `class Foo ... end`, class-side methods in `class << self`,
modules as `module`, and removed library methods as guarded `remove_method` lines. The file needs no
RubyTalk: `load` or `require` it, or send it to someone. Class list right-click > **File out class...** does
the same for one class. Without a window: `rubytalk --dir FOLDER --export FILE`.
**System > File In...** loads a `.rb` file *and records it*: a class written the ordinary way (a one-line
header, `end` last) is taken apart, so each method becomes its own change you can browse, version and revert;
`def self.x` and `class << self` become class-side methods; other statements in the body (`attr_reader`,
`include`, nested classes) are recorded as class-body statements; a method in `class String` is added to the
existing class; a class with an unusual header (`class Foo < Struct.new(:a)`) or written on one line is
recorded as a whole. Code outside any class (a `require`, a `puts`) is run but not recorded. A file in
RubyTalk's own changes format (System > Show Changes) is replayed and recorded as it is. Nothing is changed
if the file has a syntax error; a statement that fails is reported and the rest carry on. The Transcript
shows what was done, e.g. `1 class created, 6 methods, 2 other class statements, 1 top-level statement run`.
The dialogs start in the folder of the current image.

**Versions.** Accept no longer loses the old definition. Right-click a method (in the Browser or a
Method List) > **Versions...** to see, newest first: the current definition, every earlier version
kept in `changes.history`, and the **original library method** if RubyTalk has overridden or removed
one in this session or an earlier one's changes were replayed. Select one to read it; tick *Show what
reverting would change* for a line diff against the current version (`-` removed, `+` added); **Revert**
makes the selected version current. What a revert replaces is kept too, so a revert can be undone.
Reverting to the original also works for built-in methods written in C, and keeps their visibility.
**Remove method** follows the same idea: if you had overridden a method that already existed, it
restores the original; a method you created is forgotten (its source stays under Versions); removing
a library method nobody overrode is logged so it persists, and Versions can bring it back.
`changes.history` uses the same chunk format as `changes.rb`, appended to as you work (at most the
newest 100 versions of a method are shown); delete it to forget the history.

**Versions of a class.** Class list right-click > **Versions of this class...** does the same for a
class you created in RubyTalk (each Accept of its definition keeps the one it replaces) and for the
comment of a class that already existed (the last entry is then the original comment from the library's
source). Revert works the same way and can itself be undone. A class-body statement (`attr_accessor`,
`include` ...) is its own entry, identified by its text: editing one makes a new statement rather than a new
version of the old one, so statements have no version list, but a statement that is replaced or removed
(or goes with a removed class) is still kept in `changes.history`.

**Protocols.** Ruby has no protocol (category) for methods, so RubyTalk uses a convention: a comment
line `# protocol: accessing` in the comment block directly above a `def`:

```ruby
# Answers the balance.
# protocol: accessing
def balance
  @balance
end
```

The Browser's protocol list then shows, after "-- all --", the protocols the class's methods are filed
under (sorted), "as yet unclassified" if some methods have none, and then public / protected / private as
before. It follows the *instance / class* choice and *show inherited*. Select one of your protocols and the
new-method template starts with its comment, so a new method lands in it; to file a method elsewhere, edit
the comment and Accept; to start a new protocol, type `# protocol: name` above a method and Accept (the name
appears in the list). It also works for ordinary Ruby files: a library class that carries these comments is
sorted the same way. Only the comment block above the `def` counts (not comments inside the body), and C
methods are always unclassified.

**Hierarchy.** Class list right-click > **Hierarchy of this class**, or Edit > **Hierarchy of it**
(select a class name or any expression; a non-class gives its class's hierarchy). The window is a
normal browser whose class list shows the superclass chain from BasicObject down, then **all**
subclasses, each level indented one step. For a module it shows the classes that include it
directly. Browsing, the filter box, Accept (a new subclass appears and is selected), Versions and
Remove all work as usual. Lists stop at 3000 rows.

**Syntax highlighting.** Code panes (Workspace, Browser code pane, Method List, Inspector) are
coloured as Ruby: keywords, strings (including `%w[]` and heredocs), comments, numbers, symbols and
labels, constants, `@`/`$` variables, regexps, and method names after `def`. It uses Ruby's own
lexer (Ripper), so unfinished code colours as you type. The palette follows the pane's
background, so it suits both light and dark appearance (chosen when the window opens). The
Transcript is not coloured (it is mostly output), and texts over 60,000 characters are left plain
to keep typing responsive. Colours live in `Highlighter::PALETTES`.

**Inspector**: fields (instance variables, array elements, hash entries, struct members)
on the left, selected value on the right, and a pane at the bottom where `self` is the
inspected object. Double-click a field to inspect it.

## changes.rb

On startup, `./changes.rb` is replayed in order. Every accepted change is written to the file
immediately (atomically), so a crash loses nothing; it is also saved on exit. The file as it
was when you started is kept as `changes.rb.bak` (one backup per session). It records class definitions, method
definitions, class-body statements and method removals made through the Browser; redefining
a method replaces its earlier entry. Each chunk starts with a header line:

```
#!rubytalk kind=method target=Account side=instance key=deposit
def deposit(n)
  @balance += n
end
```

Nothing in the file is dropped silently:

* A chunk that fails to apply is reported in the Transcript, with a summary ("WARNING: 2 of 17 changes could
  not be applied ...") listing each one. It stays in the file and is tried again at the next start (so a
  change that needed a library you have since installed simply works).
* A chunk RubyTalk does not understand (an unknown `kind=`, a damaged header) is kept exactly as written.
* The file says which format it is in (`# format: 1` in the first lines). A file with a *newer* format
  number than your RubyTalk knows is read as far as possible but **never overwritten**; the Transcript says so,
  and System > File Out Changes as Ruby still works (chunks RubyTalk does not understand are left out of the filed-out Ruby). Files without the line (older ones) load as format 1.
* Saving writes `changes.rb.tmp`, flushes it to disk, then renames it over the real file, so a crash or a
  full disk leaves either the old file or the new one, whole. A leftover `.tmp` after a crash is harmless
  and replaced by the next save.

If a disk write ever fails, autosave turns itself off with a Transcript message, the change stays in memory,
and RubyTalk retries when you quit.
Workspace evaluations (do it / print it) are not logged or replayed.

## Layout and tests

```
bin/rubytalk                 launcher
lib/rubytalk.rb              entry point, RubyTalk.run / setup / save_changes
lib/rubytalk/transcript.rb   Transcript stream
lib/rubytalk/evaluator.rb    do it machinery, stdout redirection, error formatting
lib/rubytalk/source.rb       Ripper-based statement splitting and method-source extraction
lib/rubytalk/changes.rb      ChangeSet: parse, replay, write changes.rb
lib/rubytalk/compiler.rb     Accept, replay, remove method/class
lib/rubytalk/search.rb       implementors / senders
lib/rubytalk/explainer.rb    Explain it: what a word is (no GUI)
lib/rubytalk/diff.rb         line diff for the Versions window
lib/rubytalk/stack.rb        what the debugger shows: frames, source, variables, method to edit
lib/rubytalk/test_runner.rb  runs Minitest classes and reports plain outcomes
lib/rubytalk/finder.rb       text search and replacement behind Find (no GUI)
lib/rubytalk/indenter.rb     auto-indent rules (no GUI)
lib/rubytalk/exchange.rb     file out / file in of plain Ruby (no GUI)
lib/rubytalk/bracket_matcher.rb  matching brackets via the lexer (no GUI)
lib/rubytalk/highlighter.rb  syntax highlighting: Ripper tokens to coloured spans (no GUI)
lib/rubytalk/preferences.rb  remembers the last folder chosen
lib/rubytalk/icon.rb         the icon, drawn in code; PNG and .icns writers
lib/rubytalk/graphics/*.rb   Point, Rectangle, Form, BitBlt, Pen ... and the MVC framework (no GUI code)
lib/rubytalk/app_bundle.rb   builds RubyTalk.app
lib/rubytalk/cli.rb          command-line options
lib/rubytalk/reflection.rb   categories, method lists, definition text (no GUI)
lib/rubytalk/gui.rb          GUI module: event pump, menus, dialogs, helpers shared by all windows
lib/rubytalk/gui/layout.rb   where windows go and remembering it (GUI.place, GUI.save_layout ...)
lib/rubytalk/gui/commands.rb System-menu commands: run tests, file out / file in
lib/rubytalk/gui/*.rb        the Tk windows (browser, workspace, inspector, debugger, versions_window, method_list,
                             find_bar, test_results_window; graphics_window.rb hosts MVC windows)
lib/rubytalk/gui/self_test.rb  the --selftest runner; its checks are in gui/self_test/*_checks.rb
```

Tests live in `test/`, one file per area, each runnable on its own (`ruby test/test_core_compiler.rb`) and
all run by `rake test`. The big areas share their setup through a base class in `test/support/`:

```
test_core_*.rb               headless: evaluator and debugger support, compiler and changes.rb,
                             search and versions, file out/in, editing, test runner, reflection  (support/core_case.rb)
test_gui_*.rb                the windows against a recording stand-in for tk (test/fake/tk.rb)  (support/gui_case.rb)
test_graphics.rb             Point, Rectangle, Color, Form, BitBlt, Pen, Paths, Font, Cursor, Dependents
test_mvc_*.rb                the Model-View-Controller framework: core, widgets, input        (support/mvc_case.rb)
test_text_editing.rb         the text-editing widget and the Notes example
test_explainer.rb            Explain it, headless
test_gui_explain_spawn.rb    Explain it and Spawn in the windows
test_changes_safety.rb       changes.rb format version, atomic saves (including a real kill -9 during a save), failed chunks
test_class_versions.rb       versions of class definitions and comments
test_protocols.rb            `# protocol:` categories, in the reflection layer and the Browser
test_parsing.rb              one-pass statement splitting, Ripper syntax errors, the Senders cache, raise recording
test_highlighter.rb          syntax highlighting (token classes, byte-to-character columns, bad input)
test_icon.rb                 icon pixels, .icns structure, app bundle (runs its launcher), CLI
```

```
rake test                    everything, each file in its own process
ruby test/test_protocols.rb  one area
```

**Who owns what.** The unit tests (`test_core_*`, `test_mvc_*`, the rest) own the *logic*: what a command
computes, edge cases, error messages. `test_gui_*` owns RubyTalk's *wiring*: that a menu entry, key binding
or list click reaches the right code, against the stand-in for tk. `--selftest` owns what only real Tk can
show: it drives actual widgets (typing, selection, key and mouse events) end to end, one check per feature,
and is deliberately shallow. `test_gui_selftest.rb` runs that same self-test against the stand-in so its own
logic is covered without a display. When adding a feature: put the detailed cases in a unit or `test_gui_`
file, and add at most one `--selftest` check that proves it works through real widgets.

The GUI tests use `test/fake/tk.rb`, so they check RubyTalk's own GUI logic but cannot
validate real Tk behaviour. The fake is strict about one real-Tk trap: it raises FrozenError if
a frozen string reaches a widget (the tk gem calls `force_encoding` on what it is given), which is
why the files under `gui/` do not use `# frozen_string_literal: true`. It also runs the
`--selftest` checks, so the self-test's own logic is covered even without a display.

## Graphics: Point, Rectangle, Form, BitBlt, Pen, Paths

Smalltalk-80's graphics classes are part of RubyTalk. They are defined at the top level, as in Smalltalk, so a
Workspace can use them directly, and the browser lists them under **Graphics-Primitives**.

* `Point` (`Point.new(3, 4)`, or `3.at(4)`): immutable, with arithmetic by point or number (`p * 2`, `2 * p`),
  `dist`, `dot`, `max`/`min`, `corner`, `extent`. `Rectangle`: origin and corner (the corner is just outside),
  `contains?`, `intersect`, `merge`, `expand_by`, `inset_by`, `translate_by`.
* `Color`: red, green, blue 0 to 255 (`Color.red`, `Color.new(10, 200, 30)`, `Color.from_hex('#ff8800')`).
* `Form`: a bitmap of real pixels (`0xRRGGBB` integers). `form.fill(rect, color)`, `copy_from`, `copy`, `reverse`,
  `border`, `draw_string`, `to_ascii`, `to_ppm`, `to_png`, `Form.from_ascii`, `Form.from_ppm`. Drawing outside a
  Form is clipped. White to start with.
* `BitBlt`: the one primitive everything else uses, with the Blue Book's 16 combination rules (`BitBlt::OVER`,
  `UNDER`, `ERASE`, `REVERSE`, `INVERT` ...), a halftone pattern (a Form tiled over the area, or a colour) and a
  clip rectangle. **Rules work on "ink", where black counts as 1**, as on the original 1-bit displays: `UNDER`
  paints black over anything, `ERASE` removes it, `REVERSE` (xor) draws and a second draw undoes it. Colours
  combine channel by channel.
* `Pen`: a turtle. `Pen.new(form)` starts in the middle pointing up; `go`, `turn`, `north`, `up`/`down`, `goto`,
  `polygon`, `spiral`, `color=`, `width=`, `rule=`. Direction is in degrees, 0 east, so `turn(90)` turns right.
* `Path`, `Line`, `LinearFit`, `Arc`, `Circle`, `Spline`: shapes that `display_on(form, at:, color:, width:)`.
* `Font` (a 5x7 bitmap font, `Font.default`, drawn with `form.draw_string`) and `Cursor` (named mouse cursors).
* `Dependents`: `add_dependent`, `changed(:aspect)` and `update`, Smalltalk's dependency mechanism, used by
  `Form` and by `Model` (see MVC).

```ruby
form = Form.new(300, 200)
pen = Pen.new(form, color: Color.blue)
pen.spiral(60, 91, 2)
Circle.new(Point.new(220, 100), 50).display_on(form, color: Color.red, width: 2)
form.draw_string('Hello', Point.new(10, 10), scale: 2)
form.to_png            # PNG bytes; File.binwrite('picture.png', form.to_png)
```

## Model-View-Controller

Smalltalk-80's interface framework, listed in the browser under **Interface-Framework**. Try the two examples
from a Workspace:

```ruby
GraphicsExamples::Counter.open     # a model, a StringView and three buttons
GraphicsExamples::Sketch.open      # draw with the mouse: red draws, yellow erases, blue clears; keys 1-9 r g b k y o c
GraphicsExamples::Notes.open       # a scrolling list, a text editor and a yellow-button menu on one model
form.show                          # any Form, in a window (redraws when you call form.changed)
```

* **Model**: includes `Dependents`. Call `changed(:aspect)` after changing it and every dependent view gets
  `update(:aspect, with)`.
* **View**: owns a rectangle (`bounds`, in its superview's coordinates), holds `subviews`, and draws itself by
  overriding `display_view(form)`. **Each view draws into its own Form with 0@0 at its top-left**, so it never
  needs to know where it sits; the framework copies the result into its parent, clipped to the view. The default
  `update` redraws. `StandardSystemView.new(label, model, Point.new(w, h))` is a window; `add_subview`,
  `open`, `close`.
* **Controller**: handles the mouse and keyboard for one view (`view.controller`, made from
  `default_controller_class`). Smalltalk's controllers run a polling loop; RubyTalk is event driven, so the same
  protocol is arranged the other way round: the **ControlManager** sends the controller of the view under the
  pointer `mouse_down(point, button)`, `mouse_up`, `mouse_move`, `key_pressed(char, keysym)`, with points in the
  view's own coordinates; `control_initialize` when the pointer enters the view, `control_terminate` when it
  leaves, and `control_activity` after every event (the old loop body). The view that got a button press keeps
  the mouse until the button is up, even if you drag outside it. `sensor` (the `InputSensor`) gives
  `cursor_point` and `red_button_pressed?` etc. Buttons are named by colour as in Smalltalk: **red is the left
  button, yellow the middle, blue the right** (RubyTalk maps Tk's numbering, which differs on a Mac).
* **Widgets**: `StringView` (fixed or computed text), `ButtonView` (acts when released inside it), `ListView`
  (click to select; **scrolls**), `FormView` (shows a Form). They are ordinary views and controllers you can read
  and copy. A `ListView` longer than its area shows a scroll bar (click or drag it); the wheel or two-finger scroll
  works over the list; and after you click a list the keys Up, Down, Page Up, Page Down, Home and End move the
  selection (it keeps the keyboard wherever the pointer goes, until you click another list or text field).
* **Pop-up menus** (`PopUpMenu`, Smalltalk's yellow-button menu): `PopUpMenu.new(['Cut', '-', ['Paste', -> { paste }]]) { |index, label| ... }`;
  a label is a string, an `[label, action]` pair (the action runs when it is chosen) or `'-'` for a separator.
  A controller offers one by returning it from `menu_for(button)`; `MouseMenuController` (and so `ListController`)
  has `red_button_menu=`, `yellow_button_menu=` and `blue_button_menu=`, and the window shows the menu **instead
  of** delivering that button press: `list.controller.yellow_button_menu = PopUpMenu.new(%w[Open Delete]) { ... }`.
  From code: `menu.pop_up(window, point)` (default: where the pointer is). It works as in Smalltalk (press,
  drag to an item, release to choose; release off the menu cancels), and if you release without moving it stays
  open as a click menu: click an item to choose it, click elsewhere or press Escape to dismiss, Up/Down/Return
  work too. The menu is placed inside its window, so menus have to fit in the window.
* **Text editing** (`TextView`, with `TextController`): a monospaced editor on the built-in font.
  `TextView.new(nil, Rectangle.from(0, 0, 300, 120), text: "Hello") { |text| ... }` calls the block after every
  edit; `multiline: false` makes a one-line field (Return calls `on_accept`); `editable: false` allows selecting and
  copying only; give it a model with `aspect: :body` and it reads `model.body`, writes `model.body=` as you type
  and reloads when the model says `changed(:body)`. Click to place the caret (this gives it the keyboard); drag to
  select; **double click selects a word, triple click a line, shift-click extends**; shift with the arrow, Home, End,
  Page Up and Page Down keys selects; control (Ctrl) with Left or Right moves by words; Tab types two spaces
  (`tab_width`); **Cmd-A, C, X, V, Z** (Ctrl elsewhere) select all, copy, cut, paste and undo, using the **system
  clipboard** (`Clipboard.text`); the yellow button shows an editing menu unless you set another. It scrolls
  (wheel, scroll bar, or just typing past the edge; long lines scroll sideways). The editing is also plain methods
  (`insert`, `move(:word_right, extend: true)`, `select_word_at`, `undo`, `copy` ...), so a program can drive it.
  Without word wrap; text that is not ASCII shows as `?` in the 5x7 font.
* **Keyboard, modifiers and clicks**: a controller that returns true from `wants_keyboard_focus?` gets the keys
  after you click its view; otherwise keys go to the controller under the pointer. `sensor.shift_pressed?` and
  `sensor.control_pressed?` give the modifier keys at the last mouse or key event, and `sensor.click_count` is 1, 2
  or 3 for a single, double or triple click. Command keys (Cmd-C, Ctrl-C elsewhere) go to
  `Controller#command_key(keysym)`; return true if you used it. `mouse_wheel(point, lines)` receives the wheel
  (positive scrolls down).
* **Windows**: each StandardSystemView is a Tk window showing a picture of the view tree. The picture is
  redrawn after every event that changed something, and every 100 ms for changes made elsewhere (for example from
  a do it). An error in a controller or view is written to the Transcript, not raised into Tk.
* **Testing without a screen**: `ControlManager.new` is a window manager of your own, and
  `manager.mouse_down(window, x, y, :red)` and friends simulate a user, which is how the tests drive everything.

```ruby
class Meter < Model
  attr_reader :level
  def initialize = (super; @level = 0)
  def bump = (@level = (@level + 10) % 110; changed(:level))
end

class MeterView < View
  def display_view(form)
    form.fill(Rectangle.from(0, 0, model.level, height), Color.green)
  end
end

meter = Meter.new
window = StandardSystemView.new('Meter', meter, Point.new(120, 60))
window.add_subview(MeterView.new(meter, Rectangle.from(5, 5, 110, 20)))
window.add_subview(ButtonView.new('Bump', Rectangle.from(5, 30, 80, 24)) { meter.bump })
window.open
```

Limits: windows have a fixed size; menus cannot be taller than their window; text is the built-in 5x7 bitmap font
(ASCII only); the editor has no word wrap, no redo and no input-method (accented or non-Latin) typing; and the whole
window is redrawn on any change (fine at these sizes).

## The Tk "Console" window

On macOS, Tk opens its own window titled "Console" (a bare Tcl shell with a `%` prompt) when a program is
started without a terminal, such as RubyTalk.app from Finder. It is not part of RubyTalk, which has the
Transcript, and RubyTalk hides it at startup. `--selftest` checks that it is hidden.

## Known limits

* The debugger cannot resume or step, and shows locals only for the frame that raised (see Debugger).
* Stop cannot interrupt one long C call (see "Running code and Stop"); and code that touches Tk
  directly from a do it must hand the work to `RubyTalk::GUI.on_main { ... }` itself.
* Versions cover methods, class definitions and class comments; a class-body statement is a separate entry per
  text, so it has no list of earlier versions (see "Versions of a class").
* Protocols are a comment convention (`# protocol: name`), not something Ruby knows about: there is no
  menu to move a method between protocols, you edit the comment.
* File in decomposes classes written in the ordinary way (one-line header, `end` last). Anything fancier
  is recorded whole, so it appears as a class definition rather than as separate methods.
* Find marks at most 1000 matches on screen (all are counted and replaced).
