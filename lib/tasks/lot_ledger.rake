# frozen_string_literal: true

namespace :lot_ledger do
  desc "Rebuild FIFO lots + closures for every (portfolio, asset) with buys/sells"
  task backfill: :environment do
    pairs = PortfolioTransaction
      .joins(:transaction_type)
      .where(transaction_types: { key: LotLedger::LEDGER_TYPE_KEYS })
      .where.not(portfolio_id: nil)
      .distinct
      .pluck(:portfolio_id, :asset_id)

    puts "Rebuilding lot ledger for #{pairs.size} (portfolio, asset) pairs..."
    pairs.each do |portfolio_id, asset_id|
      oversells = LotLedger.rebuild!(portfolio_id, asset_id)
      if oversells.present?
        warn "  oversell in portfolio=#{portfolio_id} asset=#{asset_id}: #{oversells.inspect}"
      end
    end
    puts "Done. asset_lots=#{AssetLot.count} lot_closures=#{LotClosure.count}"
  end

  desc "Generate purification entries for completed quarters (optionally TODAY=YYYY-MM-DD)"
  task purify: :environment do
    today = ENV["TODAY"].present? ? Date.parse(ENV["TODAY"]) : Date.current
    Portfolio.find_each do |portfolio|
      LotLedger.generate_purifications!(portfolio.id, today: today)
    end
    puts "Purification entries: #{PurificationEntry.count} (as of #{today})"
  end
end
