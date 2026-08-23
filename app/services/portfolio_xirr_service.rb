# frozen_string_literal: true

# Builds signed cash flows in reporting currency from portfolio transactions (buy / sell / cash_dividend)
# and current NAV, then runs {XirrCalculator}. Wallet deposit/withdrawal rows are not portfolio-scoped.
# Sells: Excel wants +cash proceeds. Use +transactions.total_amount when it already matches qty×posted
# sale price. Some rows mistakenly store exit *cost basis* as total_amount; then total_amount +
# realised_gain equals proceeds and matches qty×price_per_unit—recover that amount for IRR.
class PortfolioXirrService
  FlowLine = Struct.new(:date, :amount, :kind, :label, :transaction_id, keyword_init: true)

  Breakdown = Struct.new(
    :result,
    :portfolio_stats,
    :flow_lines,
    :terminal_date,
    :terminal_amount,
    :transaction_outflows,
    :transaction_inflows,
    :present_value_at_solved_rate,
    keyword_init: true
  )

  class << self
    def call(portfolio, as_of: Time.zone.today)
      breakdown(portfolio, as_of: as_of).result
    end

    # Aggregate XIRR across multiple portfolios: combines all cash flows and sums NAVs.
    # portfolios: Array or ActiveRecord::Relation of Portfolio records.
    def overall(portfolios, as_of: Time.zone.today)
      base_id = Currency.reporting_currency_id
      as_of_d = as_of.respond_to?(:to_date) ? as_of.to_date : as_of

      combined_flows = []
      terminal = 0.to_d

      Array(portfolios).each do |p|
        flow_hashes, = transaction_flow_collections(p, base_id)
        combined_flows.concat(flow_hashes)
        terminal += PortfolioStatsService.summary(p)[:total_value].to_d
      end

      XirrCalculator.annualized_percent(combined_flows, current_value: terminal, as_of: as_of_d)
    end

    def breakdown(portfolio, as_of: Time.zone.today)
      base_id = Currency.reporting_currency_id
      portfolio_stats = PortfolioStatsService.summary(portfolio).symbolize_keys
      terminal = portfolio_stats[:total_value].to_d
      as_of_d = as_of.respond_to?(:to_date) ? as_of.to_date : as_of

      flow_hashes, flow_lines = transaction_flow_collections(portfolio, base_id)

      flows_for_calc = flow_hashes
      result = XirrCalculator.annualized_percent(flows_for_calc, current_value: terminal, as_of: as_of_d)

      tx_outflows = flow_lines.sum { |ln| ln.amount.negative? ? ln.amount.abs : 0.to_d }
      tx_inflows = flow_lines.sum { |ln| ln.amount.positive? ? ln.amount : 0.to_d }

      pv =
        if result.annualized_percent
          rd = BigDecimal(result.annualized_percent.to_s) / 100
          XirrCalculator.present_value_sum(flows_for_calc, current_value: terminal, as_of: as_of_d, annual_rate_decimal: rd.to_f)
        end

      Breakdown.new(
        result: result,
        portfolio_stats: portfolio_stats,
        flow_lines: flow_lines,
        terminal_date: as_of_d,
        terminal_amount: terminal,
        transaction_outflows: tx_outflows,
        transaction_inflows: tx_inflows,
        present_value_at_solved_rate: pv
      )
    end

    private

    def transaction_flow_collections(portfolio, base_id)
      hashes = []
      lines = []
      portfolio.portfolio_transactions.includes(:transaction_type, :currency, :asset).order(:date, :id).find_each do |tx|
        key = tx.transaction_type.key
        signed =
          case key
          when "buy"
            -convert_amount(tx, base_id)
          when "sell"
            convert_money(sell_cash_received_for_xirr(tx), tx.currency_id, base_id)
          when "cash_dividend"
            convert_amount(tx, base_id)
          else
            nil
          end
        next if signed.nil? || signed.zero?

        label = "#{tx.transaction_type.label} · #{tx.asset.code}"
        hashes << { date: tx.date, amount: signed.to_d }
        lines << FlowLine.new(
          date: tx.date,
          amount: signed.to_d,
          kind: key,
          label: label,
          transaction_id: tx.id
        )
      end
      [ hashes, lines ]
    end

    def convert_amount(tx, base_id)
      convert_money(tx.total_amount.to_d, tx.currency_id, base_id)
    end

    # Economic sale proceeds for XIRR in transaction currency (before FX).
    def sell_cash_received_for_xirr(tx)
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

    def convert_money(amount, currency_id, base_id)
      amt = amount.to_d
      return amt if base_id.blank?

      CurrencyConversionService.convert(amt, currency_id, base_id)
    end
  end
end
