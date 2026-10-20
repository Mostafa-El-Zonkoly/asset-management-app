# frozen_string_literal: true

namespace :performance do
  desc "Explain a portfolio's Wealth Return around external flows: rake 'performance:diagnose[PORTFOLIO_ID_OR_NAME,2026-10-01]'"
  task :diagnose, %i[portfolio from] => :environment do |_t, args|
    from = args[:from].present? ? Date.parse(args[:from]) : 45.days.ago.to_date
    found = false

    User.find_each do |user|
      Current.user = user
      portfolio = Portfolio.find_by(id: args[:portfolio].to_i) || Portfolio.find_by(name: args[:portfolio])
      next unless portfolio

      found = true
      base_id = Currency.reporting_currency_id
      puts "== #{portfolio.name} (id=#{portfolio.id}) | wealth basis | from #{from}"

      series = PortfolioWealthSeriesService.call(portfolio, role: "all", base_id: base_id)
      puts "source=#{series.source.inspect} available=#{series.available?} reason=#{PortfolioWealthSeriesService.reason_text(series).inspect}"
      next unless series.available?

      if series.source == :liquidity_wallet
        wallet = portfolio.liquidity_wallet
        puts "\nWallet events touching #{wallet.code} (kind, who, signed effect on wallet):"
        svc = PortfolioWealthSeriesService.new(portfolio, role: "all", base_id: base_id)
        svc.send(:wallet_effects, wallet).select { |e| e[:date] >= from }.sort_by { |e| e[:date] }.each do |e|
          own = e[:portfolio_id] == portfolio.id
          cls = if own && PortfolioWealthSeriesService::OWN_WALLET_TRANSFER_KINDS.include?(e[:kind]) then "NEUTRAL (own wallet<->portfolio)"
                elsif own && PortfolioWealthSeriesService::INTERNAL_KINDS.include?(e[:kind]) then "internal (cash<->holdings)"
                else "EXTERNAL flow"
                end
          puts format("  %s  %-15s portfolio=%-5s %14.2f  %s", e[:date], e[:kind], e[:portfolio_id].inspect, e[:amount], cls)
        end
      end

      daily = PortfolioPerformanceService.daily_series([portfolio], role: "all", basis: :wealth).select { |r| r.date >= from }
      idx = 100.0
      puts "\n#{'date'.ljust(11)} #{'wealth'.rjust(14)} #{'cash'.rjust(14)} #{'ext flow'.rjust(12)} #{'day pnl'.rjust(12)} #{'ret %'.rjust(8)} #{'index'.rjust(8)}"
      daily.each do |r|
        idx *= (1 + (r.daily_return || 0).to_f)
        flag = PortfolioPerformanceService.suspicious_days([r]).any? ? "  <== SUSPICIOUS" : ""
        puts format("%s %14.2f %14.2f %12.2f %12.2f %8.2f %8.2f%s", r.date, r.value, r.cash || 0, r.external, r.daily_pnl || 0, (r.daily_return || 0) * 100, idx, flag)
      end
      bad = PortfolioPerformanceService.suspicious_days(daily)
      puts bad.empty? ? "\nOK: no external-flow day moved performance by more than #{(PortfolioPerformanceService::JUMP_WARN_THRESHOLD * 100).to_i}%." :
                        "\n#{bad.size} suspicious day(s): the flow and the wealth value disagree on those dates (compare 'ext flow' with the change in 'wealth')."
    ensure
      Current.user = nil
    end

    puts "No portfolio matched #{args[:portfolio].inspect}" unless found
  end
end
