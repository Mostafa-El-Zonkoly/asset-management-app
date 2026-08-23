# frozen_string_literal: true

class ExchangeRateFetcherService
  class << self
    def fetch!
      Rails.logger.info("ExchangeRateFetcherService: stub — implement external API or scraping here")
      { ok: true, message: "No fetcher configured" }
    end
  end
end
