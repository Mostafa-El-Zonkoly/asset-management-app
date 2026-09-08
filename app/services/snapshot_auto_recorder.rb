# frozen_string_literal: true

# On-visit daily snapshot capture. This deployment has no background worker
# (the sidekiq-cron schedule only loads when Redis/Sidekiq is present), so
# snapshots are recorded when a value page is opened — but only once the
# Egyptian market day is settled:
#   * current time is past 15:00 Africa/Cairo, AND
#   * today's prices have been fetched (an asset_price row exists for today).
# One snapshot per portfolio per day (idempotent). Scoped to the current user
# via the models' default scope. Never raises into the request.
module SnapshotAutoRecorder
  CUTOFF_HOUR = 15
  ZONE = "Africa/Cairo"

  module_function

  def run
    now = Time.current.in_time_zone(ZONE)
    return if now.hour < CUTOFF_HOUR

    today = now.to_date
    return unless AssetPrice.where(date: today).exists?

    Portfolio.active.find_each do |portfolio|
      next if PortfolioSnapshot.exists?(portfolio_id: portfolio.id, date: today)

      PortfolioSnapshotService.record!(portfolio, as_of: today)
    end
  rescue StandardError => e
    Rails.logger.warn("[snapshot_auto] #{e.class}: #{e.message}")
  end
end
