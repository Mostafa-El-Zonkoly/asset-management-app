# frozen_string_literal: true

class ExchangeRateFetchJob < ApplicationJob
  queue_as :default

  def perform(user_id = nil)
    ExchangeRateFetcherService.fetch!
    return if user_id.blank?

    Turbo::StreamsChannel.broadcast_replace_to(
      "rates_#{user_id}",
      target: "exchange_rate_fetch_status",
      partial: "settings/exchange_rates/fetch_status",
      locals: { message: "Exchange rate fetch finished (stub)." }
    )
  end
end
