# frozen_string_literal: true

class PriceFetchJob < ApplicationJob
  queue_as :default

  def perform(user_id = nil)
    status_message = "Price fetch finished."

    begin
      summary = PriceFetcherService.fetch_all(run_id: job_id)
      status_message = if summary[:failed].positive?
                         "Price fetch finished: #{summary[:success]}/#{summary[:total]} succeeded, #{summary[:failed]} failed."
                       else
                         "Price fetch finished: #{summary[:success]} updated."
                       end
    rescue StandardError => e
      status_message = "Price fetch failed: #{e.message}"
      raise
    ensure
      if user_id.present?
        PriceFetchStatusTracker.finish!(user_id, message: "#{status_message} Run ID #{job_id}")
        Turbo::StreamsChannel.broadcast_replace_to(
          "prices_#{user_id}",
          target: "price_fetch_controls",
          partial: "prices/fetch_controls",
          locals: { status: PriceFetchStatusTracker.status_for(user_id) }
        )
      end
    end
  end
end
