# frozen_string_literal: true

require "bigdecimal"

# Reconstructs historical daily value snapshots from transaction history and the
# stored price series, so Sharpe / value-history have data without waiting weeks.
#
# For every trading day that has prices (from `asset_prices`), it replays each
# portfolio's non-wallet holdings as of that day and values them at the latest
# price on or before that day (carry-forward), converting to the reporting
# currency at current FX (historical FX isn't stored — fine for a single-currency
# book, approximate otherwise). Existing snapshots are never overwritten.
class PortfolioSnapshotBackfillService
  QTY_TYPES = %w[buy sell stock_dividend].freeze

  Txn = Struct.new(:date, :asset_id, :signed_qty)

  class << self
    def call
      new.call
    end
  end

  def call
    reporting_id = Currency.reporting_currency_id
    return { error: "No base/reporting currency set." } if reporting_id.blank?

    price_dates = AssetPrice.distinct.order(:date).pluck(:date)
    return { created: 0, portfolios: 0, dates: 0 } if price_dates.empty?

    created = 0
    portfolios = 0
    Portfolio.active.find_each do |portfolio|
      portfolios += 1
      created += backfill_portfolio(portfolio, price_dates, reporting_id)
    end

    { created: created, portfolios: portfolios, dates: price_dates.size }
  end

  private

  def backfill_portfolio(portfolio, price_dates, reporting_id)
    txns = quantity_txns(portfolio)
    return 0 if txns.empty?

    first_date = txns.first.date
    dates = price_dates.select { |d| d >= first_date }
    return 0 if dates.empty?

    asset_ids = txns.map(&:asset_id).uniq
    assets = Asset.where(id: asset_ids).index_by(&:id)
    series = asset_ids.index_with do |aid|
      AssetPrice.where(asset_id: aid, currency_id: assets[aid].currency_id).order(:date).pluck(:date, :price)
    end

    existing = PortfolioSnapshot.where(portfolio_id: portfolio.id).pluck(:date).to_set

    running = Hash.new(0.to_d)
    ti = 0
    created = 0

    dates.each do |d|
      while ti < txns.size && txns[ti].date <= d
        running[txns[ti].asset_id] += txns[ti].signed_qty
        ti += 1
      end
      next if existing.include?(d)

      value = 0.to_d
      running.each do |aid, qty|
        next unless qty.positive?

        price = price_asof(series[aid], d)
        next if price.nil?

        value += CurrencyConversionService.convert(qty * price, assets[aid].currency_id, reporting_id).to_d
      end
      next unless value.positive?

      begin
        PortfolioSnapshot.create!(portfolio_id: portfolio.id, date: d, total_value: value, currency_id: reporting_id)
        created += 1
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end

    created
  end

  # Non-wallet buy/sell/stock_dividend, ordered by date, as signed quantities.
  def quantity_txns(portfolio)
    portfolio.portfolio_transactions
      .joins(:transaction_type)
      .includes(:asset)
      .where(transaction_types: { key: QTY_TYPES })
      .order(:date, :id)
      .filter_map do |t|
        next if t.asset&.wallet?

        sign = t.transaction_type.key == "sell" ? -1 : 1
        Txn.new(t.date.to_date, t.asset_id, t.quantity.to_d * sign)
      end
  end

  # Latest price with date <= d (carry-forward). series is [[date, price], ...] asc.
  def price_asof(series, d)
    return nil if series.blank?

    lo = 0
    hi = series.size - 1
    ans = nil
    while lo <= hi
      mid = (lo + hi) / 2
      if series[mid][0] <= d
        ans = series[mid][1]
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    ans&.to_d
  end
end
