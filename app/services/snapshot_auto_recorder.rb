# frozen_string_literal: true

# On-visit daily maintenance (this deployment has no background worker/cron).
# When a value page is opened AND it's past 15:00 Africa/Cairo:
#   * if today's prices haven't been fetched, kick off a price fetch (async,
#     non-blocking) once per day, then wait for a later visit; otherwise
#   * record one snapshot per active portfolio for today (idempotent).
# Scoped to the current user; never raises into the request.
module SnapshotAutoRecorder
  CUTOFF_HOUR = 15
  ZONE = "Africa/Cairo"

  module_function

  def run(user_id = nil)
    now = Time.current.in_time_zone(ZONE)
    return if now.hour < CUTOFF_HOUR

    today = now.to_date

    unless AssetPrice.where(date: today).exists?
      ensure_prices_fetched(today, user_id)
      return
    end

    Portfolio.active.find_each do |portfolio|
      next if PortfolioSnapshot.exists?(portfolio_id: portfolio.id, date: today)

      PortfolioSnapshotService.record!(portfolio, as_of: today)
    end
  rescue StandardError => e
    Rails.logger.warn("[snapshot_auto] #{e.class}: #{e.message}")
  end

  # Enqueue a price fetch at most once per day (async adapter runs it in-process).
  def ensure_prices_fetched(today, user_id)
    return if user_id.blank?
    return if defined?(PriceFetchStatusTracker) && PriceFetchStatusTracker.running?(user_id)

    key = "auto_price_fetch:#{user_id}:#{today}"
    return if Rails.cache.exist?(key)

    Rails.cache.write(key, true, expires_in: 30.minutes)
    PriceFetchJob.perform_later(user_id)
  rescue StandardError => e
    Rails.logger.warn("[snapshot_auto] price fetch enqueue failed: #{e.class}: #{e.message}")
  end
end
