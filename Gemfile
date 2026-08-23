source "https://rubygems.org"

gem "rails", "~> 7.2.3"
gem "sprockets-rails"
gem "pg", "~> 1.5"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails"
gem "jbuilder"
gem "redis", ">= 4.0.1"
gem "sidekiq", "~> 7.0"
gem "sidekiq-cron", "~> 1.12"
gem "devise", "~> 4.9"
gem "httparty"
gem "groupdate"
gem "ransack"
gem "pagy", "~> 9.0"
gem "faraday"
gem "nokogiri"

gem "tzinfo-data", platforms: %i[ windows jruby ]
gem "bootsnap", require: false

group :development, :test do
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  # Minitest 6 breaks Rails 7.2 test line filtering (ArgumentError in line_filtering.rb).
  gem "minitest", "~> 5.25"
end
