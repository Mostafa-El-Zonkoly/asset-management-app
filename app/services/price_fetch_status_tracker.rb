# frozen_string_literal: true

class PriceFetchStatusTracker
  RUNNING_TTL = 2.hours
  FINISHED_TTL = 6.hours

  class << self
    def start!(user_id)
      update_running!(user_id, message: "Fetching prices...")
    end

    def update_running!(user_id, message:)
      current = status_for(user_id)
      Rails.cache.write(
        cache_key(user_id),
        current.merge(running: true, message: message, started_at: current[:started_at] || Time.current.iso8601),
        expires_in: RUNNING_TTL
      )
    end

    def finish!(user_id, message:)
      Rails.cache.write(
        cache_key(user_id),
        { running: false, message: message, finished_at: Time.current.iso8601 },
        expires_in: FINISHED_TTL
      )
    end

    def running?(user_id)
      status_for(user_id).fetch(:running, false)
    end

    def status_for(user_id)
      Rails.cache.read(cache_key(user_id)) || default_status
    end

    private

    def cache_key(user_id)
      "price_fetch_status:user:#{user_id}"
    end

    def default_status
      { running: false, message: "Ready." }
    end
  end
end
