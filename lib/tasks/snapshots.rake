# frozen_string_literal: true

namespace :snapshots do
  desc "Backfill historical portfolio value snapshots from price history (all users)"
  task backfill: :environment do
    User.find_each do |user|
      Current.user = user
      result = PortfolioSnapshotBackfillService.call
      puts "user=#{user.id}: #{result.inspect}"
    ensure
      Current.user = nil
    end
  end
end
