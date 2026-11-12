# frozen_string_literal: true

source 'https://rubygems.org'

# Development tools. The 'tk' gem is deliberately NOT here: the unit and smoke tests run against a
# recording stand-in for Tk (test/fake/tk.rb), so they need no Tcl/Tk, and CI stays easy to set up.
# To run the real GUI and `rake selftest`, install Tcl/Tk and then `gem install tk`, or:
#   bundle config set --local with gui && bundle install
group :development do
  gem 'minitest', '~> 5.0' # Minitest 6 moved minitest/mock out into its own gem; the tests use it
  gem 'rake'
  gem 'rubocop', require: false
end

group :gui, optional: true do
  gem 'tk'
end
