# frozen_string_literal: true

require "bigdecimal"

# Reconstructs a portfolio's daily holdings VALUE series and cash-FLOW series for a
# given Position Role ("all" | "base" | "temporary"), from transaction history +
# stored prices. Used for filtered historical performance (spec #24): the split is
# derived from history (role-tagged lots/closures), never by applying today's
# filter to the past.
#
#   series = PortfolioValueSeriesService.call(portfolio, role: "base")
#   series.values  # => [[Date, value_bd], ...] ascending, one per price date >= inception
#   series.flows   # => { Date => Day(external:, dividend:) }  (reporting currency)
#
# role "all" reconciles to the whole-portfolio holdings value (cross-checks against
# stored snapshots). Values use latest price on/before each date (carry-forward)
# converted at current FX (historical FX isn't stored), matching the existing
# snapshot backfill.
class PortfolioValueSeriesService
  Series = Struct.new(:values, :flows, :inception, keyword_init: true)

  class << self
    def call(portfolio, role: "all", base_id: nil)
      new(portfolio, role: role, base_id: base_id).call
    end
  end

  def initialize(portfolio, role:, base_id:)
    @portfolio = portfolio
    @role = role.to_s
    @base_id = base_id || Currency.reporting_currency_id
  end

  def call
    txns = ledger_txns
    return Series.new(values: [], flows: {}, inception: nil) if txns.empty? || @base_id.blank?

    by_asset = txns.group_by(&:asset_id)
    assets = Asset.where(id: by_asset.keys).index_by(&:id)

    # Per-asset: role-filtered cumulative quantity deltas by date, from Fifo lots/closures.
    qty_deltas = Hash.new { |h, aid| h[aid] = Hash.new(0.to_d) } # aid => {date => delta}
    sell_role_fraction = {} # sell_tx_id => role_qty / total_qty (for flow attribution)

    by_asset.each do |aid, asset_txns|
      result = LotLedger::Fifo.compute(asset_txns.map { |t| LotLedger.event_for(t) })

      result[:lots].each do |lot|
        next unless role_match?(lot.position_role)

        qty_deltas[aid][lot.opened_on] += lot.original_qty.to_d
      end
      result[:closures].each do |c|
        # role of the closed lot; reduces that role's remaining
        qty_deltas[aid][c.closed_on] -= c.qty.to_d if role_match?(c.position_role)
      end

      # Per-sell role fraction for proceeds attribution.
      totals = Hash.new(0.to_d)
      role_totals = Hash.new(0.to_d)
      result[:closures].each do |c|
        totals[c.sell_id] += c.qty.to_d
        role_totals[c.sell_id] += c.qty.to_d if role_match?(c.position_role)
      end
      totals.each_key do |sid|
        sell_role_fraction[sid] = totals[sid].nonzero? ? (role_totals[sid] / totals[sid]) : 0.to_d
      end
    end

    inception = txns.map { |t| t.date.to_date }.min
    price_dates = AssetPrice.distinct.where("date >= ?", inception).order(:date).pluck(:date)
    return Series.new(values: [], flows: flows_for(txns, sell_role_fraction, by_asset), inception: inception) if price_dates.empty?

    price_series = by_asset.keys.index_with do |aid|
      AssetPrice.where(asset_id: aid, currency_id: assets[aid].currency_id).order(:date).pluck(:date, :price)
    end

    # Cumulative role qty per asset, marched forward across price dates.
    sorted_delta_dates = qty_deltas.transform_values { |m| m.keys.sort }
    idx = Hash.new(0)
    running = Hash.new(0.to_d)

    values = price_dates.map do |d|
      total = 0.to_d
      by_asset.each_key do |aid|
        dates = sorted_delta_dates[aid]
        while idx[aid] < dates.size && dates[idx[aid]] <= d
          running[aid] += qty_deltas[aid][dates[idx[aid]]]
          idx[aid] += 1
        end
        qty = running[aid]
        next unless qty.positive?

        price = price_asof(price_series[aid], d)
        next if price.nil?

        total += convert(qty * price, assets[aid].currency_id)
      end
      [d, total]
    end

    Series.new(values: values, flows: flows_for(txns, sell_role_fraction, by_asset), inception: inception)
  end

  private

  # Role-filtered external + dividend flows, reporting currency, keyed by date.
  def flows_for(txns, sell_role_fraction, by_asset)
    days = Hash.new { |h, k| h[k] = PortfolioCashFlowService::Day.new(external: 0.to_d, dividend: 0.to_d) }

    # Buys / sells (external capital) + cash dividends (income), reporting currency.
    dividend_txns = @portfolio.portfolio_transactions
                              .joins(:transaction_type)
                              .includes(:asset)
                              .where(transaction_types: { key: "cash_dividend" })
                              .to_a

    txns.each do |t|
      d = t.date.to_date
      key = t.transaction_type.key
      case key
      when "buy"
        next unless role_match?(t.position_role)

        days[d].external += convert(t.total_amount.to_d, t.currency_id)
      when "sell"
        frac = sell_role_fraction[t.id] || (@role == "all" ? 1.to_d : 0.to_d)
        next if frac.zero?

        days[d].external -= convert(t.total_amount.to_d, t.currency_id) * frac
      end
    end

    dividend_txns.each do |t|
      next if t.asset&.wallet?

      frac = @role == "all" ? 1.to_d : role_qty_fraction(t)
      next if frac.zero?

      days[t.date.to_date].dividend += convert(t.total_amount.to_d, t.currency_id) * frac
    end

    days
  end

  # Fraction of the asset's holding that is in @role at the dividend date, for
  # attributing dividend income to a role subset (approximate; exact for "all").
  def role_qty_fraction(dividend_tx)
    return 1.to_d if @role == "all"

    asset_txns = @portfolio.portfolio_transactions
                           .joins(:transaction_type)
                           .where(asset_id: dividend_tx.asset_id)
                           .where(transaction_types: { key: LotLedger::LEDGER_TYPE_KEYS })
                           .where("transactions.date <= ?", dividend_tx.date)
                           .order(:date, :id).to_a
    return 0.to_d if asset_txns.empty?

    result = LotLedger::Fifo.compute(asset_txns.map { |t| LotLedger.event_for(t) })
    total = 0.to_d
    role_q = 0.to_d
    result[:lots].each do |lot|
      rem = lot.remaining_qty.to_d
      next unless rem.positive?

      total += rem
      role_q += rem if role_match?(lot.position_role)
    end
    total.nonzero? ? (role_q / total) : 0.to_d
  end

  def ledger_txns
    @portfolio.portfolio_transactions
              .joins(:transaction_type)
              .includes(:asset, :transaction_type)
              .where(transaction_types: { key: LotLedger::LEDGER_TYPE_KEYS })
              .order(:date, :id)
              .reject { |t| t.asset&.wallet? }
  end

  def role_match?(lot_role)
    return true if @role == "all"

    lot_role.to_s == @role
  end

  def convert(amount, from_ccy)
    return amount.to_d if from_ccy == @base_id

    CurrencyConversionService.convert(amount, from_ccy, @base_id).to_d
  rescue StandardError
    amount.to_d
  end

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
