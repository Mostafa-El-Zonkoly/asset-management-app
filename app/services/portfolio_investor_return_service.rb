# frozen_string_literal: true

require "bigdecimal"

# Investor-flow performance (spec J/K/L/M). External flows are ONLY contributions,
# withdrawals and portfolio transfers — never buys/sells (internal recycling).
#
#   XIRR : money-weighted return from dated investor flows + terminal NAV.
#          contribution = -, withdrawal/transfer_out = +, transfer_in = -,
#          opening_capital = - on migration_on, terminal NAV = +.
#   TWR  : time-weighted return from the daily NAV series (cash + holdings), with
#          external flows closing sub-periods. Buys/sells are NAV-neutral (cash down,
#          holdings up), so they never break a TWR period.
#
# Master variants exclude transfers (they net to zero across the book).
class PortfolioInvestorReturnService
  HALF = BigDecimal("0.5")

  class << self
    def xirr(portfolio, as_of: Date.current, base_id: nil)
      new(base_id: base_id).xirr([portfolio], as_of: as_of, master: false)
    end

    def xirr_master(portfolios, as_of: Date.current, base_id: nil)
      new(base_id: base_id).xirr(portfolios, as_of: as_of, master: true)
    end

    def twr(portfolio, as_of: Date.current, base_id: nil)
      new(base_id: base_id).twr([portfolio], as_of: as_of, master: false)
    end

    def twr_master(portfolios, as_of: Date.current, base_id: nil)
      new(base_id: base_id).twr(portfolios, as_of: as_of, master: true)
    end
  end

  def initialize(base_id: nil)
    @base_id = base_id || Currency.reporting_currency_id
  end

  # => XirrCalculator::Result (annualized_percent may be nil with a reason).
  def xirr(portfolios, as_of:, master:)
    flows = []
    nav = 0.to_d
    portfolios.each do |p|
      acct = PortfolioAccountingService.call(p, base_id: @base_id)
      nav += acct.nav
      if (oc = p.opening_capital) && oc.opening_capital.to_d.positive?
        flows << { date: oc.migration_on, amount: -reporting(oc.opening_capital, oc.currency_id) }
      end
      p.portfolio_cash_flows.find_each do |f|
        next if master && f.transfer? # transfers net out at Master level

        amt = reporting(f.amount, f.currency_id)
        signed = case f.kind
                 when "contribution", "transfer_in" then -amt # money in to investments
                 when "withdrawal", "transfer_out" then amt    # money out
                 end
        flows << { date: f.occurred_at.to_date, amount: signed }
      end
    end
    XirrCalculator.annualized_percent(flows, current_value: nav, as_of: as_of)
  end

  # => BigDecimal percent, or nil when there is not enough NAV history.
  def twr(portfolios, as_of:, master:)
    values = nav_series(portfolios, as_of: as_of)
    return nil if values.size < 2

    flows = flow_series(portfolios, master: master)
    prev = nil
    factor = 1.to_d
    values.each do |(d, v)|
      f = flows[d] || 0.to_d
      if prev
        denom = prev + (f * HALF)
        r = denom.zero? ? 0.to_d : ((v - prev - f) / denom)
        factor *= (1 + r)
      end
      prev = v
    end
    (factor - 1) * 100
  end

  private

  # Daily NAV = holdings MV (from stored snapshots) + cash path (opening + tx + flows).
  def nav_series(portfolios, as_of:)
    holdings_by_date = merged_holdings(portfolios, as_of)
    return [] if holdings_by_date.empty?

    dates = holdings_by_date.keys.sort
    dates.map { |d| [d, holdings_by_date[d] + cash_at(portfolios, d)] }
  end

  def merged_holdings(portfolios, as_of)
    per = portfolios.map do |p|
      PortfolioSnapshot.where(portfolio_id: p.id).where("date <= ?", as_of).order(:date).pluck(:date, :total_value)
    end
    per.reject!(&:blank?)
    return {} if per.empty?

    all_dates = per.flat_map { |ser| ser.map(&:first) }.uniq.sort
    cursors = Array.new(per.size, 0)
    carried = Array.new(per.size, 0.to_d)
    out = {}
    all_dates.each do |d|
      total = 0.to_d
      per.each_with_index do |ser, i|
        while cursors[i] < ser.size && ser[cursors[i]][0] <= d
          carried[i] = ser[cursors[i]][1].to_d
          cursors[i] += 1
        end
        total += carried[i]
      end
      out[d] = total
    end
    out
  end

  # Portfolio cash as of date d across the set: opening_cash + tx effects (after
  # migration) + cash-flow effects, all with date/occurred_at <= d.
  def cash_at(portfolios, d)
    total = 0.to_d
    portfolios.each do |p|
      oc = p.opening_capital
      migration_on = oc&.migration_on || PortfolioAccountingService::EPOCH
      total += oc&.opening_cash.to_d
      p.portfolio_transactions.joins(:transaction_type)
       .where(transaction_types: { key: PortfolioAccountingService::CASH_TX_SIGN.keys })
       .where("transactions.date > ? AND transactions.date <= ?", migration_on.end_of_day, d.end_of_day)
       .find_each { |tx| total += reporting(tx.total_amount, tx.currency_id) * PortfolioAccountingService::CASH_TX_SIGN[tx.transaction_type.key] }
      p.portfolio_cash_flows.where("occurred_at <= ?", d.end_of_day)
       .find_each { |f| total += reporting(f.amount, f.currency_id) * f.cash_sign }
    end
    total
  end

  # External flow per day = signed investor cash (contributions/withdrawals/transfers).
  def flow_series(portfolios, master:)
    days = Hash.new(0.to_d)
    portfolios.each do |p|
      p.portfolio_cash_flows.find_each do |f|
        next if master && f.transfer?

        days[f.occurred_at.to_date] += reporting(f.amount, f.currency_id) * f.cash_sign
      end
    end
    days
  end

  def reporting(amount, currency_id)
    a = amount.to_d
    return a if @base_id.blank? || currency_id == @base_id

    CurrencyConversionService.convert(a, currency_id, @base_id).to_d
  rescue StandardError
    amount.to_d
  end
end
