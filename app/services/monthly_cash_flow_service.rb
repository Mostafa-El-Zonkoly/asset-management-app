# frozen_string_literal: true

# Aggregates deposits, withdrawals, and per-portfolio buy/sell totals by calendar month
# (amounts in reporting currency). Wallet-only ledger rows are not portfolio-scoped;
# buy/sell rows never target wallet assets.
class MonthlyCashFlowService
  PortfolioMonth = Struct.new(:portfolio_id, :name, :buys, :sells, :net, keyword_init: true)
  MonthSummary = Struct.new(
    :month,
    :label,
    :deposits,
    :withdrawals,
    :net_investment,
    :portfolios,
    keyword_init: true
  )

  Report = Struct.new(:months, :portfolios, keyword_init: true)

  class << self
    def call
      new.call
    end
  end

  def call
    base_id = Currency.reporting_currency_id
    portfolios = Portfolio.order(:name).to_a
    portfolio_names = portfolios.index_by(&:id).transform_values(&:name)

    buckets = Hash.new do |h, month|
      h[month] = {
        deposits: 0.to_d,
        withdrawals: 0.to_d,
        portfolios: Hash.new { |ph, pid| ph[pid] = { buys: 0.to_d, sells: 0.to_d } }
      }
    end

    PortfolioTransaction
      .includes(:transaction_type, :currency, :asset)
      .joins(:transaction_type)
      .where(transaction_types: { key: %w[deposit withdrawal buy sell] })
      .find_each do |tx|
        key = tx.transaction_type.key
        month = tx.date.to_date.beginning_of_month
        bucket = buckets[month]

        case key
        when "deposit"
          bucket[:deposits] += reporting_amount(tx, base_id, key)
        when "withdrawal"
          bucket[:withdrawals] += reporting_amount(tx, base_id, key)
        when "buy"
          next if tx.portfolio_id.blank? || tx.asset.wallet?

          bucket[:portfolios][tx.portfolio_id][:buys] += reporting_amount(tx, base_id, key)
        when "sell"
          next if tx.portfolio_id.blank? || tx.asset.wallet?

          bucket[:portfolios][tx.portfolio_id][:sells] += reporting_amount(tx, base_id, key)
        end
      end

    months = buckets.keys.sort.reverse.map do |month|
      data = buckets[month]
      portfolio_rows = build_portfolio_rows(data[:portfolios], portfolio_names)
      net_investment = portfolio_rows.sum(&:net)

      MonthSummary.new(
        month: month,
        label: I18n.l(month, format: "%B %Y"),
        deposits: data[:deposits],
        withdrawals: data[:withdrawals],
        net_investment: net_investment,
        portfolios: portfolio_rows
      )
    end

    Report.new(months: months, portfolios: portfolios)
  end

  private

  def build_portfolio_rows(portfolio_data, portfolio_names)
    portfolio_data.filter_map do |portfolio_id, totals|
      buys = totals[:buys]
      sells = totals[:sells]
      next if buys.zero? && sells.zero?

      PortfolioMonth.new(
        portfolio_id: portfolio_id,
        name: portfolio_names[portfolio_id] || "Portfolio ##{portfolio_id}",
        buys: buys,
        sells: sells,
        net: buys - sells
      )
    end.sort_by(&:name)
  end

  def reporting_amount(tx, base_id, key)
    raw =
      case key
      when "sell" then sell_proceeds(tx)
      else tx.total_amount.to_d
      end
    convert(raw, tx.currency_id, base_id)
  end

  def convert(amount, currency_id, base_id)
    return amount if base_id.blank?

    CurrencyConversionService.convert(amount, currency_id, base_id)
  end

  def sell_proceeds(tx)
    t = tx.total_amount.to_d
    qty = tx.quantity.to_d
    px = tx.price_per_unit&.to_d
    return t unless qty.positive? && px&.positive?

    pq = qty * px
    return t if amounts_close?(t, pq)

    rg = tx.realised_gain&.to_d
    if rg&.nonzero?
      candidate = t + rg
      return candidate if amounts_close?(candidate, pq)
    end

    t
  end

  def amounts_close?(a, b)
    aa = a.to_d
    bb = b.to_d
    diff = (aa - bb).abs
    return true if diff <= BigDecimal("0.019")

    max_mag = [ aa.abs, bb.abs ].max
    max_mag.positive? ? (diff <= max_mag * BigDecimal("1e-8")) : false
  end
end
