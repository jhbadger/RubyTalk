# frozen_string_literal: true

# changes.rb safety: format version, atomic saves, failed and unknown entries are never lost.
#   ruby test/test_changes_safety.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rubytalk'

class ChangesSafetyTest < Minitest::Test
  include RubyTalk

  def setup
    Transcript.clear
    @dir = Dir.mktmpdir('rubytalk-safety')
    @path = File.join(@dir, 'changes.rb')
    RubyTalk.changes = ChangeSet.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    %i[RtSafe RtSafeLate].each { |name| Object.send(:remove_const, name) if Object.const_defined?(name) }
  end

  def loaded(text)
    File.write(@path, text)
    changes = ChangeSet.new(@path)
    RubyTalk.changes = changes
    changes.load!
    changes
  end

  CLASS_CHUNK = "#!rubytalk kind=class target=RtSafe created=true\nclass RtSafe\n  def hi; :hi; end\nend\n"

  # --- format version ---------------------------------------------------------------

  def test_a_saved_file_states_its_format
    changes = ChangeSet.new(@path)
    changes.record(kind: :class, target: 'RtSafe', source: "class RtSafe\nend\n", created: true)
    changes.save!
    assert_match(/^# format: #{ChangeSet::FORMAT_VERSION}$/, File.read(@path))
    assert_equal ChangeSet::FORMAT_VERSION, ChangeSet.format_of(File.read(@path))
  end

  def test_a_file_without_a_format_line_is_an_old_file_and_loads_normally
    changes = loaded("# RubyTalk changes file.\n#{CLASS_CHUNK}")
    assert_nil changes.file_format
    refute changes.newer_format?
    assert_equal :hi, RtSafe.new.hi
    assert_empty changes.failed_entries
  end

  def test_format_line_is_only_read_before_the_first_chunk
    assert_nil ChangeSet.format_of("#{CLASS_CHUNK}# format: 99\n")
    assert_equal 7, ChangeSet.format_of("# a\n# format: 7\n#{CLASS_CHUNK}")
  end

  def test_a_newer_file_is_read_but_never_overwritten
    text = "# RubyTalk changes file.\n# format: #{ChangeSet::FORMAT_VERSION + 1}\n#{CLASS_CHUNK}"
    changes = loaded(text)
    assert changes.newer_format?
    assert_match(/newer than this RubyTalk understands.*will NOT be overwritten/m, Transcript.buffer)
    assert_equal :hi, RtSafe.new.hi, 'what can be understood is still applied'

    changes.record(kind: :method, target: 'RtSafe', key: 'x', source: "def x; 1; end\n")
    assert_nil changes.save!, 'saving is refused'
    assert_equal text, File.read(@path), 'the file is byte-for-byte what it was'
    assert_match(/Not saving changes\.rb.*File Out Changes as Ruby/m, Transcript.buffer)

    Transcript.clear
    changes.record(kind: :method, target: 'RtSafe', key: 'y', source: "def y; 1; end\n")
    assert_nil changes.save!
    assert_empty Transcript.buffer, 'the refusal is announced once, not on every Accept'
  end

  # --- nothing is dropped silently ----------------------------------------------------

  def test_an_unknown_kind_is_kept_exactly_as_written
    chunk = "#!rubytalk kind=widget target=RtSafe key=w flavour=odd\nmake_widget :w\n"
    changes = loaded("#{CLASS_CHUNK}\n#{chunk}")
    assert_equal :hi, RtSafe.new.hi, 'the known chunk still applies'
    assert_equal 1, changes.failed_entries.size
    assert_match(/unknown kind of change/, Transcript.buffer)

    changes.record(kind: :method, target: 'RtSafe', key: 'z', source: "def z; 1; end\n")
    changes.save!
    saved = File.read(@path)
    assert_includes saved, "#!rubytalk kind=widget target=RtSafe key=w flavour=odd\nmake_widget :w\n",
                    'header (with its unknown attribute) and body survive a save unchanged'
    assert_includes saved, 'key=z'
  end

  def test_a_damaged_header_does_not_crash_loading_and_is_kept
    changes = loaded("#{CLASS_CHUNK}\n#!rubytalk this-is-not-a-header\nstuff\n")
    assert_equal :hi, RtSafe.new.hi
    assert_equal 1, changes.failed_entries.size
    changes.record(kind: :method, target: 'RtSafe', key: 'z', source: "def z; 1; end\n")
    changes.save!
    assert_includes File.read(@path), "#!rubytalk this-is-not-a-header\nstuff"
  end

  def test_failed_entries_are_listed_in_a_banner_and_kept
    bad = "#!rubytalk kind=method target=RtSafeLate side=instance key=late\ndef late; :late; end\n"
    changes = loaded("#{CLASS_CHUNK}\n#{bad}")
    assert_equal ['method RtSafeLate#late'], changes.failed_entries.map(&:to_s)
    assert_match(/WARNING: 1 of 2 changes could not be applied\. They are still in changes\.rb and will be tried again next time/,
                 Transcript.buffer)
    assert_match(/^  not applied: method RtSafeLate#late$/, Transcript.buffer)

    changes.record(kind: :method, target: 'RtSafe', key: 'z', source: "def z; 1; end\n")
    changes.save!
    assert_includes File.read(@path), 'key=late', 'a save keeps the failed chunk'
  end

  def test_a_failed_entry_is_retried_on_the_next_start
    bad = "#!rubytalk kind=method target=RtSafeLate side=instance key=late\ndef late; :late; end\n"
    loaded(bad)
    Object.const_set(:RtSafeLate, Class.new) # whatever was missing is there now
    Transcript.clear
    changes = ChangeSet.new(@path)
    changes.load!
    assert_empty changes.failed_entries
    assert_equal :late, RtSafeLate.new.late
    refute_match(/WARNING/, Transcript.buffer)
  end

  def test_a_clean_load_prints_no_warning
    loaded(CLASS_CHUNK)
    refute_match(/WARNING/, Transcript.buffer)
    assert_match(/Loaded 1 of 1 changes/, Transcript.buffer)
  end

  # --- atomic saves -------------------------------------------------------------------

  def test_a_failed_rename_leaves_the_old_file_whole_and_no_temp_file
    changes = ChangeSet.new(@path)
    changes.record(kind: :class, target: 'RtSafe', source: "class RtSafe\nend\n", created: true)
    changes.save!
    original = File.read(@path)

    changes.record(kind: :method, target: 'RtSafe', key: 'x', source: "def x; 1; end\n")
    File.stub(:rename, ->(*) { raise Errno::EIO }) do
      assert_raises(Errno::EIO) { changes.save! }
    end
    assert_equal original, File.read(@path), 'the file on disk is untouched'
    refute File.exist?("#{@path}.tmp"), 'no half-written temp file is left behind'
    assert changes.dirty?, 'the change is still waiting to be saved'

    assert_equal @path, changes.save!, 'the next save succeeds'
    assert_includes File.read(@path), 'key=x'
  end

  def test_autosave_survives_a_disk_error_and_says_so
    changes = ChangeSet.new(@path)
    changes.autosave = true
    File.stub(:rename, ->(*) { raise Errno::ENOSPC }) do
      changes.record(kind: :class, target: 'RtSafe', source: "class RtSafe\nend\n", created: true) # must not raise
    end
    assert_match(/autosave disabled/, Transcript.buffer)
    assert changes.dirty?
    refute File.exist?("#{@path}.tmp")
  end

  def test_a_stale_temp_file_from_an_earlier_crash_is_harmless
    File.write(@path, CLASS_CHUNK)
    File.write("#{@path}.tmp", "#!rubytalk kind=class target=Garbage\nclass Gar") # torn write
    changes = ChangeSet.new(@path)
    changes.load!
    assert_equal :hi, RtSafe.new.hi
    refute Object.const_defined?(:Garbage), 'the temp file is never read'
    changes.record(kind: :method, target: 'RtSafe', key: 'x', source: "def x; 1; end\n")
    changes.save!
    refute File.exist?("#{@path}.tmp"), 'the next save replaces and renames it'
    assert_includes File.read(@path), 'key=x'
  end

  # A real crash: the child process kills itself (SIGKILL: no ensure blocks, no at_exit) at the chosen
  # moment of a save. The file must be the old one, whole, and RubyTalk must start from it afterwards.
  def crash_during_save(moment)
    script = <<~RUBY
      $LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})
      require 'rubytalk'
      changes = RubyTalk::ChangeSet.new(#{@path.inspect})
      changes.load!
      kill = ->(*) { Process.kill('KILL', Process.pid) }
      #{moment}
      changes.record(kind: :method, target: 'RtSafe', key: 'new_method', source: "def new_method; 2; end\\n")
      changes.save!
    RUBY
    _out, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    assert status.signaled?, 'the child really was killed mid-save'
  end

  def test_killed_just_before_the_rename_the_old_file_is_intact
    File.write(@path, CLASS_CHUNK)
    before = File.read(@path)
    crash_during_save("File.singleton_class.send(:define_method, :rename, &kill)")
    assert_equal before, File.read(@path)
    assert File.exist?("#{@path}.tmp"), 'the finished temp file is left (harmless)'

    changes = ChangeSet.new(@path)
    changes.load!
    assert_equal :hi, RtSafe.new.hi
    assert_empty changes.failed_entries
  end

  def test_killed_in_the_middle_of_writing_the_old_file_is_intact
    File.write(@path, CLASS_CHUNK)
    before = File.read(@path)
    crash_during_save("IO.send(:define_method, :fsync, &kill)") # after the bytes are written, before the rename
    assert_equal before, File.read(@path)
    changes = ChangeSet.new(@path)
    changes.load!
    assert_equal :hi, RtSafe.new.hi
    refute changes.entries.any? { |entry| entry.key == 'new_method' }, 'the unsaved change is not half-present'
  end
end
