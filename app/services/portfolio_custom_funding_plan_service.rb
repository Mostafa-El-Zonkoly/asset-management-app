# frozen_string_literal: true

# Computes a "manual" funding plan where the user specifies an explicit addition
# amount for each portfolio bucket (and optionally free cash wallets).
#
# The service returns a hash describing:
#   - Each row's current value, user-specified addition, resulted value, and
#     the resulting overall weight % both before and after the additions.
#   - Deviation of the resulted value vs the row's whole-portfolio target
#     (both as an absolute amount and as percentage points of resulted_total).
#   - Summary totals (total addition, current total, resulted total).
class PortfolioCustomFundingPlanService
  class << self
    # amounts:       Hash { portfolio_id (Integer or String) => addition_amount (Numeric) }
    # wallet_amount: optional Numeric addition to free-cash wallets
    def build(amounts: {}, wallet_amount: 0)
      new(amounts: amounts, wallet_amount: wallet_amount).build
    end
  end

  def initialize(amounts: {}, wallet_amount: 0)
    @amounts = amounts.transform_keys { |k| k.to_i }.transform_values { |v| BigDecimal(v.to_s) rescue 0.to_d }
    @wallet_amount = BigDecimal(wallet_amount.to_s) rescue 0.to_d
  end

  def build
    portfolio_rows = build_portfolio_rows
    wallet_row     = build_wallet_row

    all_rows = portfolio_rows
    all_rows << wallet_row if wallet_row

    current_total  = all_rows.sum { |r| r[:current_value] }
    total_addition = all_rows.sum { |r| r[:addition] }
    resulted_total = current_total + total_addition

    rows_with_pcts = all_rows.map do |row|
      current_pct    = pct(row[:current_value], current_total)
      resulted_value = row[:current_value] + row[:addition]
      resulted_pct   = pct(resulted_value, resulted_total)
      pct_change     = resulted_pct - current_pct

      row.merge(
        current_pct:    current_pct,
        resulted_value: resulted_value,
        resulted_pct:   resulted_pct,
        pct_change:     pct_change
      )
    end

    rows_with_deviations = rows_with_pcts.map do |row|
      dev_amount, dev_pct = deviation_after_add(row, resulted_total)
      row.merge(
        deviation_after_add_amount: dev_amount,
        deviation_after_add_pct:    dev_pct
      )
    end

    {
      rows:           rows_with_deviations,
      current_total:  current_total,
      total_addition: total_addition,
      resulted_total: resulted_total
    }
  end

  private

  def build_portfolio_rows
    wealth = PortfolioStatsService.wealth_total_for_share_percent

    Portfolio.order(:name).filter_map do |portfolio|
      next nil unless portfolio.include_in_combined_percent

      stats         = PortfolioStatsService.summary(portfolio)
      current_value = stats[:total_value].to_d
      addition      = [@amounts.fetch(portfolio.id, 0.to_d), 0.to_d].max
      whole         = PortfolioStatsService.whole_portfolio_target_metrics(
        portfolio,
        combined_total_value: wealth
      )

      {
        kind:          :portfolio,
        name:          portfolio.name,
        portfolio:     portfolio,
        current_value: current_value,
        addition:      addition,
        whole_target:  whole
      }
    end
  end

  def build_wallet_row
    metrics = PortfolioStatsService.free_cash_target_metrics
    return nil if metrics.blank?

    addition = [@wallet_amount, 0.to_d].max

    {
      kind:          :wallet,
      name:          "Free cash wallets",
      portfolio:     nil,
      current_value: metrics[:actual].to_d,
      addition:      addition,
      whole_target:  metrics   # already has mode: :percentage, target_pct
    }
  end

  # Returns [deviation_amount, deviation_pct] vs the row's whole-portfolio target,
  # evaluated at resulted_total.  Both are nil when no target is configured.
  #
  # deviation_amount: resulted_value − target_value   (positive = over target)
  # deviation_pct:    deviation_amount / resulted_total * 100  (percentage points)
  def deviation_after_add(row, resulted_total)
    whole          = row[:whole_target]
    resulted_value = row[:resulted_value].to_d
    return [nil, nil] if whole.blank?

    target_value =
      case whole[:mode]
      when :percentage
        tgt_pct = whole[:target_pct]
        return [nil, nil] if tgt_pct.nil?

        resulted_total.to_d * tgt_pct.to_d / 100.to_d
      when :static_amount
        tgt = whole[:target_amount]
        return [nil, nil] if tgt.nil?

        tgt.to_d
      else
        return [nil, nil]
      end

    dev_amount = resulted_value - target_value
    dev_pct    = pct(dev_amount, resulted_total)
    [dev_amount, dev_pct]
  end

  def pct(value, total)
    return 0.to_d if total.to_d.zero?

    (value.to_d / total.to_d) * 100.to_d
  end
end
