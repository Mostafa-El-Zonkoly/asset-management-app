# frozen_string_literal: true

class CurrencyConversionService
  class << self
    # Uses latest ExchangeRate rows: either (from → to) or inverted (to → from) as 1/rate.
    # Amounts in asset/transaction currency are converted into the reporting (base) currency.
    def rate(from_currency_id, to_currency_id)
      return 1.to_d if from_currency_id == to_currency_id

      row = ExchangeRate.where(currency_id: from_currency_id, base_currency_id: to_currency_id)
        .order(date: :desc).first
      return row.rate if row

      inv = ExchangeRate.where(currency_id: to_currency_id, base_currency_id: from_currency_id)
        .order(date: :desc).first
      return (1.to_d / inv.rate) if inv&.rate&.nonzero?

      1.to_d
    end

    # Look up the rate on or before a specific date (falls back to latest if none found before date).
    def rate_on_date(from_currency_id, to_currency_id, date)
      return 1.to_d if from_currency_id == to_currency_id || date.nil?

      d = date.to_date

      row = ExchangeRate.where(currency_id: from_currency_id, base_currency_id: to_currency_id)
        .where("date <= ?", d).order(date: :desc).first
      return row.rate.to_d if row

      inv = ExchangeRate.where(currency_id: to_currency_id, base_currency_id: from_currency_id)
        .where("date <= ?", d).order(date: :desc).first
      return (1.to_d / inv.rate.to_d) if inv&.rate&.nonzero?

      # Fall back to latest known rate
      rate(from_currency_id, to_currency_id)
    end

    def convert(amount, from_currency_id, to_currency_id)
      amount.to_d * rate(from_currency_id, to_currency_id)
    end

    def rate_exists?(from_currency_id, to_currency_id)
      return true if from_currency_id.blank? || to_currency_id.blank?
      return true if from_currency_id == to_currency_id

      ExchangeRate.where(currency_id: from_currency_id, base_currency_id: to_currency_id).exists? ||
        ExchangeRate.where(currency_id: to_currency_id, base_currency_id: from_currency_id).exists?
    end

    def rate_missing?(from_currency_id, to_currency_id)
      !rate_exists?(from_currency_id, to_currency_id)
    end
  end
end
