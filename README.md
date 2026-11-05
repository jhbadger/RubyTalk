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

It cannot test things that need a person; see the checklist at the end.

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
| Accept     | Cmd-S    | Ctrl-S   | (Browser code pane) compile and log the code           |

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

A chunk that fails to apply is reported in the Transcript and kept in the file. If a disk
write ever fails, autosave turns itself off with a Transcript message and RubyTalk retries
when you quit.
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
lib/rubytalk/reflection.rb   categories, method lists, definition text (no GUI)
lib/rubytalk/gui/*.rb        Tk windows (gui/self_test.rb is the --selftest)
test/test_core.rb            headless tests of everything above
test/test_gui_smoke.rb       drives the windows against a recording stand-in for tk
```

```
ruby test/test_core.rb
ruby test/test_gui_smoke.rb
```

The smoke test uses `test/fake/tk.rb`, so it checks RubyTalk's own GUI logic but cannot
validate real Tk behaviour. The fake is strict about one real-Tk trap: it raises FrozenError if
a frozen string reaches a widget (the tk gem calls `force_encoding` on what it is given), which is
why the files under `gui/` do not use `# frozen_string_literal: true`. It also runs the
`--selftest` checks, so the self-test's own logic is covered even without a display.

## Manual checklist (things --selftest cannot do)

1. Right-click in a code pane, a class list and a method list: the pop-up menus appear and
   their items work. (On a Mac, Control-click and two-finger click should both work.)
2. Windows open staggered, not stacked exactly on top of each other.
3. Quit from the System menu, closing the Transcript window, and Cmd-Q each end the program;
   `changes.rb` is up to date afterwards.
4. Make a change, then kill the process (`kill -9`); restart: the change is still there.
5. Type in the filter box above the class list: the list narrows as you type.

## Known limits

* No resumable debugger: an error unwinds the stack; you get the message and backtrace.
* A runaway do it blocks the window; Ctrl-C in the terminal that started RubyTalk
  raises `Interrupt` in the evaluation.
* No class comments or protocol names of your own: Ruby has no equivalent, so the protocol
  list is Ruby's visibility.
* Removing a method that you earlier overrode on a built-in class removes the method
  entirely (the original is not restored until you restart and drop the change).
