# frozen_string_literal: true

class ChartRangeHelper
  class << self
    def range(key)
      k = key.to_s.downcase
      case k
      when "1w" then 1.week.ago.to_date..Date.current
      when "1m" then 1.month.ago.to_date..Date.current
      when "3m" then 3.months.ago.to_date..Date.current
      when "1y" then 1.year.ago.to_date..Date.current
      when "ytd" then Date.current.beginning_of_year..Date.current
      when "cw" then Date.current.beginning_of_week(:sunday)..Date.current
      when "cm" then Date.current.beginning_of_month..Date.current
      when "cy" then Date.current.beginning_of_year..Date.current
      when "all" then nil
      else
        if k.include?("..")
          a, b = k.split("..", 2).map { |s| Date.parse(s.strip) }
          a..b
        else
          3.months.ago.to_date..Date.current
        end
      end
    end

    # Preset `range` is used unless both `from` and `to` are present (custom window).
    def range_key_from_params(range:, from:, to:)
      if from.present? && to.present?
        a = Date.parse(from.to_s)
        b = Date.parse(to.to_s)
        a, b = b, a if a > b
        "#{a.iso8601}..#{b.iso8601}"
      else
        (range.presence || "3m")
      end
    end
  end
end
