# frozen_string_literal: true

# Sidekiq + Redis are OPTIONAL in the Render deployment.
#
# This app runs on Render without Redis, using the :async Active Job adapter
# (see config/environments/production.rb). This initializer is therefore a
# no-op unless REDIS_URL is present, which lets the app boot with no Redis.
#
# To re-enable Sidekiq later: provision Redis, set REDIS_URL, add a worker
# service running `bundle exec sidekiq -C config/sidekiq.yml`, and set
# config.active_job.queue_adapter = :sidekiq in production.rb.
if ENV["REDIS_URL"].present?
  require "sidekiq/cron/job"

  Sidekiq.configure_server do |config|
    config.redis = { url: ENV.fetch("REDIS_URL") }

    schedule_file = Rails.root.join("config/schedule.yml")
    if File.exist?(schedule_file)
      Sidekiq::Cron::Job.load_from_hash YAML.load_file(schedule_file)
    end
  end

  Sidekiq.configure_client do |config|
    config.redis = { url: ENV.fetch("REDIS_URL") }
  end
end
