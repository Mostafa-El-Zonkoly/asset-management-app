# frozen_string_literal: true

# Deliberately public and unauthenticated: this app's Render free-tier setup
# has no Sidekiq/Redis worker or built-in cron (see render.yaml), so there is
# no automatic daily price fetch. This endpoint exists to be pinged by an
# external scheduler (cron-job.org, UptimeRobot, GitHub Actions cron, etc.)
# to trigger price fetching on a schedule without needing to store any
# credentials in that scheduler.
#
# It inherits directly from ActionController::Base (not ApplicationController)
# so it skips Devise's authenticate_user!, the Current.user assignment, and
# the allow_browser modern-browser check -- none of which make sense for a
# machine-to-machine webhook hit by a cron service, not a browser.
#
# Because Current.user is left nil, TenantScoped's default_scope does not
# filter by user, so PriceFetcherService.fetch_all (called from
# PriceFetchJob) fetches prices for every user's assets, not just one.
class PublicController < ActionController::Base
  protect_from_forgery with: :null_session

  PRICE_FETCH_TRACKER_ID = "public_api"

  # GET /public/fetch_prices
  #
  # Enqueues a price fetch for all assets across all users and returns
  # immediately (jobs run in-process via the :async Active Job adapter, so
  # this does not block the request). Guards against piling up duplicate
  # fetches if the endpoint is pinged again while one is still running.
  def fetch_prices
    if PriceFetchStatusTracker.running?(PRICE_FETCH_TRACKER_ID)
      render json: {
        ok: true,
        enqueued: false,
        message: "A price fetch triggered via the public API is already running."
      }
      return
    end

    PriceFetchStatusTracker.start!(PRICE_FETCH_TRACKER_ID)
    PriceFetchJob.perform_later(PRICE_FETCH_TRACKER_ID)

    render json: {
      ok: true,
      enqueued: true,
      message: "Price fetch enqueued for all users' assets."
    }
  end
end
