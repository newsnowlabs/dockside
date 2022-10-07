# frozen_string_literal: true

source 'https://rubygems.org'

gem 'github-pages', '> 103', group: :jekyll_plugins

# Install ffi from github for compatibility with linux/arm/v7
gem 'ffi', github: 'ffi/ffi', submodules: true

group :jekyll_plugins do
  gem 'jekyll-octicons'
  # need lazy-load support
  gem 'jekyll-avatar'
end

group :development, :test do
  gem 'html-proofer'
  gem 'parallel'
  gem 'rake'
  gem 'rubocop'
  gem 'typhoeus'
end

gem "webrick", "~> 1.7"
