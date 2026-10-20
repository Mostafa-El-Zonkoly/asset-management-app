# frozen_string_literal: true

require "json"

# TEMPORARY diagnostics for the performance engine, off by default.
#
#   DEBUG_PERFORMANCE=1            enable (any of 1/true/yes/on)
#   DEBUG_PERFORMANCE_DAYS=90      only the last N valuation days per series (default 90);
#                                  days with an external flow or a suspicious jump are
#                                  always logged
#
# One JSON object per line, prefixed "[PERF_DEBUG]", so
#   grep '\[PERF_DEBUG\]' log/production.log
# reconstructs exactly why an index moved. Only ids, dates and amounts are logged (no
# names, emails or credentials). Remove this file + its call sites when done.
module PerformanceDebugLog
  PREFIX = "[PERF_DEBUG]"

  class << self
    attr_writer :sink # tests inject a lambda(line)

    def enabled?
      ENV["DEBUG_PERFORMANCE"].to_s.match?(/\A(1|true|yes|on)\z/i)
    end

    def window_days
      Integer(ENV.fetch("DEBUG_PERFORMANCE_DAYS", "90"), exception: false) || 90
    end

    def emit(hash)
      line = "#{PREFIX} #{hash.to_json}"
      if @sink
        @sink.call(line)
      elsif defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.info(line)
      else
        warn(line)
      end
    end

    # rows: PortfolioPerformanceService::DayReturn list (ascending).
    # Logs the engine inputs/outputs per date and the cumulative index of the series.
    def log_daily(rows, scope:, basis:, suspicious: [])
      return unless enabled?

      emit(event: "series", scope: scope, basis: basis, days: rows.size,
           first: rows.first&.date&.iso8601, last: rows.last&.date&.iso8601)
      cutoff = rows.size - window_days
      flagged = suspicious.map(&:date)
      cum = 1.0
      prev_value = nil
      rows.each_with_index do |r, i|
        cum *= (1 + (r.daily_return || 0).to_f)
        if i >= cutoff || r.external.nonzero? || flagged.include?(r.date)
          cash = r.cash
          emit(event: "day", scope: scope, basis: basis, date: r.date.iso8601,
               previous_total_wealth: prev_value&.to_f&.round(2),
               holdings_market_value: (cash ? r.value - cash : r.value).to_f.round(2),
               cash_balance: cash&.to_f&.round(2),
               external_deposits: [r.external, 0].max.to_f.round(2),
               external_withdrawals: [-r.external, 0].max.to_f.round(2),
               dividends: r.dividend.to_f.round(2),
               internal_cash_in: [r.internal.to_d, 0].max.to_f.round(2),   # sells + dividends settled to cash
               internal_cash_out: [-r.internal.to_d, 0].max.to_f.round(2), # buys + fees paid from cash
               ending_total_wealth: r.value.to_f.round(2),
               day_pnl: r.daily_pnl&.to_f&.round(2),
               calculated_period_return: r.daily_return&.to_f&.round(6),
               cumulative_return: (cum - 1).round(6),
               suspicious: flagged.include?(r.date))
        end
        prev_value = r.value
      end
    end

    # Chart level: the base-100 points actually sent to the browser.
    def log_normalized(label, points, start_on:, mode:)
      return unless enabled?

      prev = nil
      points.each_with_index do |p, i|
        step = prev ? ((p[1] / prev) - 1) * 100 : 0.0
        if i >= points.size - window_days || step.abs > 2
          emit(event: "normalized", series: label, mode: mode, common_start: start_on&.iso8601,
               date: p[0], normalized_index: p[1], step_pct: step.round(4), value: p[3], pnl: p[4])
        end
        prev = p[1]
      end
    end
  end
end
