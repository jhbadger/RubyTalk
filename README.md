# RubyTalk

A Smalltalk-80 style programming environment for Ruby, built on Ruby/Tk.

## Run

```
gem install tk            # needs Tcl/Tk; on macOS: brew install tcl-tk
cd ~/some/project         # RubyTalk looks for ./changes.rb here
ruby ~/lib/src/rubytalk/bin/rubytalk (or put the file on your path)
```

Run it as a script, not from `irb` (Ruby/Tk crashed inside irb on macOS in testing).

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

**Inspector**: fields (instance variables, array elements, hash entries, struct members)
on the left, selected value on the right, and a pane at the bottom where `self` is the
inspected object. Double-click a field to inspect it.

## changes.rb

On startup, `./changes.rb` is replayed in order. On exit it is rewritten if anything changed
(the previous file is kept as `changes.rb.bak`). It records class definitions, method
definitions, class-body statements and method removals made through the Browser; redefining
a method replaces its earlier entry. Each chunk starts with a header line:

```
#!rubytalk kind=method target=Account side=instance key=deposit
def deposit(n)
  @balance += n
end
```

A chunk that fails to apply is reported in the Transcript and kept in the file.
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
lib/rubytalk/reflection.rb   categories, method lists, definition text (no GUI)
lib/rubytalk/gui/*.rb        Tk windows
test/test_core.rb            headless tests of everything above
test/test_gui_smoke.rb       drives the windows against a recording stand-in for tk
```

```
ruby test/test_core.rb
ruby test/test_gui_smoke.rb
```

The smoke test uses `test/fake/tk.rb`, so it checks RubyTalk's own GUI logic but cannot
validate real Tk behaviour.

## Known limits

* No resumable debugger: an error unwinds the stack; you get the message and backtrace.
* A runaway do it blocks the window; Ctrl-C in the terminal that started RubyTalk
  raises `Interrupt` in the evaluation.
* No senders/implementors, no class comments or protocol names of your own: Ruby has no
  equivalent, so the protocol list is Ruby's visibility.
* Removing a method that you earlier overrode on a built-in class removes the method
  entirely (the original is not restored until you restart and drop the change).
