# frozen_string_literal: true

# rake            run the tests (same as `rake test`)
# rake test       every test file, each in its own process (they set up Ruby and Tk differently)
# rake selftest   drive the real windows with real Tk (needs Tcl/Tk and the tk gem; see README)
# rake rubocop    style check
# rake build      build rubytalk-<version>.gem into pkg/

require 'rbconfig'

TEST_FILES = FileList['test/test_*.rb'].sort.freeze

desc 'Run every test file in its own process'
task :test do
  failed = TEST_FILES.reject do |file|
    puts "\n== #{file}"
    system(RbConfig.ruby, '-Ilib', '-Itest', file)
  end
  abort "\nFailed: #{failed.join(', ')}" unless failed.empty?
  puts "\nAll #{TEST_FILES.size} test files passed."
end

desc 'Drive the real windows with real Tk (needs a display and the tk gem)'
task :selftest do
  sh RbConfig.ruby, 'bin/rubytalk', '--selftest'
end

desc 'Check style with RuboCop'
task :rubocop do
  sh 'rubocop'
end

desc 'Build the gem into pkg/'
task :build do
  mkdir_p 'pkg'
  sh 'gem', 'build', 'rubytalk.gemspec', '--output', "pkg/rubytalk-#{File.read('lib/rubytalk/version.rb')[/'([^']+)'/, 1]}.gem"
end

task default: :test
