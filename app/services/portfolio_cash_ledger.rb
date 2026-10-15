# frozen_string_literal: true

require "bigdecimal"

# Pure (no DB) retained-cash ledger for ONE portfolio, replayed by date.
#
# It mirrors how PortfolioAccountingService.cash is defined, but answers "what was
# the cash on date d?" instead of "what is it now?":
#
#   cash(d) = opening_cash
#           + Σ tx_events  with  migration_on < date <= d   (buy -, sell +,
#                                                           cash_dividend +, deduction -)
#           + Σ flow_events with date <= d                   (contribution/transfer_in +,
#                                                           withdrawal/transfer_out -)
#
# tx_events / flow_events are [[Date, signed_amount_in_reporting_ccy], ...]. The
# signs are applied by the caller (PortfolioWealthSeriesService) using the SAME
# PortfolioAccountingService::CASH_TX_SIGN / PortfolioCashFlow#cash_sign the rest of
# the app uses, so fees/taxes/dividends keep their existing treatment.
#
# Transactions dated on/before migration_on are NOT replayed: the opening cash is
# the user-declared position at that date, and earlier history is not trusted for
# cash (we never fabricate historical cash).
class PortfolioCashLedger
  EPSILON = BigDecimal("0.0001")

  attr_reader :opening_cash, :migration_on

  # boundary_events: external flows that do NOT change this cash balance (e.g. a buy settled
  # through a different wallet: holdings change, this cash does not). They are reported in
  # external_flows_by_day so the return engine neutralises them, but never enter cash_on.
  def initialize(opening_cash:, migration_on:, tx_events: [], flow_events: [], boundary_events: [])
    @opening_cash = opening_cash.to_d
    @migration_on = migration_on
    @tx = group_and_accumulate(tx_events.select { |d, _| d > migration_on })
    @flow_events = flow_events
    @boundary_events = boundary_events
    @flows = group_and_accumulate(flow_events)
  end

  # Cash balance at the END of +date+.
  def cash_on(date)
    opening_cash + cumulative(@tx, date) + cumulative(@flows, date)
  end

  # { Date => net signed EXTERNAL cash flow that day } (contribution/transfer_in +,
  # withdrawal/transfer_out -). This is the only thing that is not performance.
  def external_flows_by_day
    (@flow_events + @boundary_events).each_with_object(Hash.new(0.to_d)) { |(d, amt), h| h[d] += amt.to_d }
  end

  # First date in +dates+ on which cash is below zero (cash went negative because a
  # buy was never funded by a recorded contribution), else nil.
  def first_negative_date(dates)
    dates.find { |d| cash_on(d) < -EPSILON }
  end

  private

  # => { sorted_dates: [...], cum: [...] } so cumulative lookups are O(log n).
  def group_and_accumulate(events)
    by_day = events.each_with_object(Hash.new(0.to_d)) { |(d, amt), h| h[d] += amt.to_d }
    dates = by_day.keys.sort
    running = 0.to_d
    cum = dates.map { |d| running += by_day[d] }
    { dates: dates, cum: cum }
  end

  def cumulative(acc, date)
    i = acc[:dates].bsearch_index { |d| d > date }
    idx = i.nil? ? acc[:dates].size - 1 : i - 1
    idx.negative? ? 0.to_d : acc[:cum][idx]
  end
end
