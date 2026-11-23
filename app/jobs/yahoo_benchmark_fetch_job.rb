# frozen_string_literal: true

require Rails.root.join("lib/yahoo_finance/index_rails_adapter")

class YahooBenchmarkFetchJob < ApplicationJob
  queue_as :default

  def perform(user_id, date)
    summary = Current.set(user: User.find(user_id)) do
      indices = MarketIndex.benchmarks.where(is_active: true)
                           .where("UPPER(TRIM(code)) IN (?)", YahooFinance::IndexRailsAdapter::SYMBOLS.keys)
                           .to_a
      log(:info, "started", user_id: user_id, date: date, total: indices.size)
      BenchmarkPriceFetcherService.fetch_all(date: Date.iso8601(date), run_id: job_id, indices: indices)
    end

    log(:info, "finished", user_id: user_id, date: date, updated: summary[:success], failed: summary[:failed])
    message = if summary[:total].zero?
                "No active benchmarks configured."
              else
                "Yahoo Finance benchmarks finished. #{summary[:success]} updated, #{summary[:failed]} failed."
              end
    summary[:results].reject { |result| result[:ok] }.each do |failure|
      message += " #{failure.fetch(:code)} — #{failure.fetch(:error)}"
    end
  rescue StandardError => e
    log(:error, "failed", user_id: user_id, date: date, error_class: e.class.name)
    message = "Yahoo Finance benchmark fetch failed."
    raise
  ensure
    PriceFetchStatusTracker.finish!(user_id, message: "#{message} Run ID #{job_id}")
    Turbo::StreamsChannel.broadcast_replace_to(
      "prices_#{user_id}",
      target: "price_fetch_controls",
      partial: "prices/fetch_controls",
      locals: { status: PriceFetchStatusTracker.status_for(user_id) }
    )
    Turbo::StreamsChannel.broadcast_refresh_to("prices_#{user_id}") if summary && summary[:success].positive?
  end

  private

  def log(severity, event, **fields)
    Rails.logger.public_send(severity, { provider: "yahoo_finance", job: "yahoo_benchmark_fetch", run_id: job_id, event: event, **fields }.to_json)
  end
end
