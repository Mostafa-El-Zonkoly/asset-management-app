# frozen_string_literal: true

class AddPerformanceFieldsToPortfolioSnapshots < ActiveRecord::Migration[7.2]
  def change
    # total_value already holds the portfolio's non-wallet holdings market value
    # in the reporting currency; it keeps its meaning. These add the cash-flow and
    # return context needed for time-weighted performance. All are derived from the
    # stored value series + frozen transactions, so they never change when live
    # prices update.
    change_table :portfolio_snapshots, bulk: true do |t|
      # Net external capital that entered the portfolio's holdings on this day,
      # reporting currency: buys(+cost) minus sells(-proceeds). Dividends are income,
      # tracked separately, not here.
      t.decimal :external_cash_flow, precision: 20, scale: 8
      # Cash dividend income recognised on this day (reporting currency).
      t.decimal :dividend_income, precision: 20, scale: 8
      # Daily Modified Dietz investment return (fraction, e.g. 0.0142 = +1.42%).
      # Null when there is no prior snapshot or the base is zero.
      t.decimal :daily_return, precision: 20, scale: 10
      # Daily investment P&L (reporting currency) = end - start - external_cash_flow + dividend_income.
      t.decimal :daily_pnl, precision: 20, scale: 8
      # Cumulative net external capital contributed up to and including this day.
      t.decimal :invested_value, precision: 20, scale: 8
    end
  end
end
