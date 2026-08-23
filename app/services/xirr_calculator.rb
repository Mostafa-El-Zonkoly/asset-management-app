# frozen_string_literal: true

# Excel-style XIRR: solve sum_i C_i * (1+r)^(-y_i) = 0 where y_i is years from the earliest date (365-day year).
# Cash-flow sign convention: negative = money into investments, positive = out (sales, dividends, terminal NAV).
class XirrCalculator
  Result = Struct.new(:annualized_percent, :reason, keyword_init: true)

  MIN_ONE_PLUS_R = 1e-10
  MAX_ITERATIONS = 100
  NPV_TOLERANCE = 1e-7
  DERIVATIVE_EPS = 1e-14

  class << self
    # @param flows [Array<Hash>] each element has :date / :amount (or string keys)
    # @param current_value [Numeric] terminal positive inflow (e.g. mark-to-market)
    # @param as_of [Date, Time]
    # @return [Result] annualized_percent is e.g. BigDecimal("12.5") for 12.5%/year, or nil with :reason
    def annualized_percent(flows, current_value:, as_of: Time.zone.today)
      combined = normalize_combined(flows, current_value, as_of)
      case validation_reason(combined)
      when :insufficient_flows
        return Result.new(annualized_percent: nil, reason: :insufficient_flows)
      when :same_sign
        return Result.new(annualized_percent: nil, reason: :same_sign)
      end

      rows = build_rows(combined)
      rate = solve_newton(rows)
      return Result.new(annualized_percent: nil, reason: rate[:reason]) if rate[:reason]

      pct = BigDecimal(rate[:r].to_s) * 100
      Result.new(annualized_percent: pct, reason: nil)
    end

    # Net present value of the same dated sequence used by {#annualized_percent}, at annual rate +rate_annual_decimal+ (e.g. 0.12 for 12%).
    # Returns a Float aligned with internal Newton evaluation; magnitude should be negligible at the solved rate.
    def present_value_sum(flows, current_value:, as_of:, annual_rate_decimal:)
      combined = normalize_combined(flows, current_value, as_of)
      rows = build_rows(combined)
      r = annual_rate_decimal.to_f
      base = 1.0 + r
      return Float::NAN unless base.finite? && base > MIN_ONE_PLUS_R

      rows.sum { |amt, y| amt * base**(-y) }
    end

    private

    def normalize_combined(flows, current_value, as_of)
      as_of_date = as_of.respond_to?(:to_date) ? as_of.to_date : as_of
      list = Array(flows).map { |h| normalize_flow_hash(h) }
      list << { date: as_of_date, amount: current_value.to_d }
      list
    end

    def normalize_flow_hash(h)
      d = h[:date] || h["date"]
      a = h[:amount] || h["amount"]
      { date: d.respond_to?(:to_date) ? d.to_date : d, amount: a.to_d }
    end

    def validation_reason(combined)
      return :insufficient_flows if combined.size < 2

      pos = combined.any? { |row| row[:amount].positive? }
      neg = combined.any? { |row| row[:amount].negative? }
      return :same_sign unless pos && neg

      nil
    end

    def build_rows(combined)
      d0 = combined.min_by { |r| r[:date] }[:date]
      combined.map do |row|
        days = (row[:date] - d0).to_f
        y = days / 365.0
        [ row[:amount].to_f, y ]
      end
    end

    def solve_newton(rows)
      r = 0.1
      MAX_ITERATIONS.times do
        base = 1.0 + r
        return { reason: :invalid_rate } if base <= MIN_ONE_PLUS_R || !r.finite?

        f = 0.0
        df = 0.0
        rows.each do |amt, y|
          f += amt * base**(-y)
          df += -y * amt * base**(-(y + 1))
        end

        return { r: r } if f.abs < NPV_TOLERANCE
        return { reason: :no_convergence } if df.abs < DERIVATIVE_EPS || !df.finite?

        r -= f / df
        return { reason: :no_convergence } if !r.finite? || r.abs > 1e6
      end

      { reason: :no_convergence }
    end
  end
end
