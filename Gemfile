# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", ">= 13.3"

gem "rails", "~> 8.1.0"
gem "puma", ">= 7.2"

group :development, :test do
  gem "minitest", ">= 5.25"
  gem "mocha", ">= 2.0"
  gem "rack-test"
  gem "webmock"
  gem "capybara"
  gem "selenium-webdriver"

  gem "appraisal", "~> 2.5"
  gem "parallel", "< 2.1"

  gem "rubocop", "~> 1.86", ">= 1.86.1", require: false
  gem "rubocop-minitest", "~> 0.39.1", require: false
  gem "rubocop-rake", "~> 0.7.1", require: false

  gem "brakeman", require: false
  gem "bundler-audit", require: false
end
