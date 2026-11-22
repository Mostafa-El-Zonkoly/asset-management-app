# frozen_string_literal: true

class EfgBenchmarkFetchJob < ApplicationJob
  queue_as :default

  def perform(user_id, date)
    summary = Current.set(user: User.find(user_id)) do
      EfgBenchmarkPriceFetcher.new(run_id: job_id, date: Date.iso8601(date)).call
    end
    message = if summary[:total].zero?
                "No active benchmarks configured."
              else
                "EFG benchmarks finished. #{summary[:updated]} updated, #{summary[:failed]} failed."
              end
  rescue StandardError => e
    Rails.logger.error({ job: "efg_benchmark_fetch", run_id: job_id, user_id: user_id, event: "failed", error_class: e.class.name }.to_json)
    message = "EFG benchmark fetch failed."
    raise
  ensure
    PriceFetchStatusTracker.finish!(user_id, message: "#{message} Run ID #{job_id}")
    Turbo::StreamsChannel.broadcast_replace_to(
      "prices_#{user_id}",
      target: "price_fetch_controls",
      partial: "prices/fetch_controls",
      locals: { status: PriceFetchStatusTracker.status_for(user_id) }
    )
    Turbo::StreamsChannel.broadcast_refresh_to("prices_#{user_id}") if summary && summary[:updated].positive?
  end
end
