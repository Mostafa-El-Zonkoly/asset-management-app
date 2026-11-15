# frozen_string_literal: true

# Find (and optionally delete) asset prices saved by the broken Mubasher scraper.
# After Mubasher moved to a single-page app, the old HTML heuristics saved the `8`
# from `<meta charset="utf-8">` as the price of every scraped asset.
#
#   rake prices:find_bogus_scraped              # dry run: list suspect rows
#   rake "prices:find_bogus_scraped[8]"         # custom suspect value
#   DELETE=1 rake prices:find_bogus_scraped     # delete the listed rows
namespace :prices do
  desc "List (or DELETE=1 to remove) scraped asset prices equal to a suspect value (default 8)"
  task :find_bogus_scraped, [:value] => :environment do |_t, args|
    value = BigDecimal((args[:value] || "8").to_s)
    source = PriceSource.find_by(key: "scraped")
    abort "No 'scraped' price source found." unless source

    scope = AssetPrice.includes(:asset).where(price_source: source, price: value).order(:date)
    rows = scope.to_a

    if rows.empty?
      puts "No scraped prices equal to #{value.to_s('F')} found."
      next
    end

    rows.group_by(&:asset).sort_by { |a, _| a&.code.to_s }.each do |asset, prices|
      puts format("%-12s %4d rows  %s .. %s", asset&.code || "?", prices.size, prices.first.date, prices.last.date)
    end
    puts "Total: #{rows.size} rows across #{rows.map(&:asset_id).uniq.size} assets."

    if ENV["DELETE"] == "1"
      deleted = AssetPrice.where(id: rows.map(&:id)).delete_all
      puts "Deleted #{deleted} rows. Re-run the price fetch to record correct prices for today."
    else
      puts "Dry run. Re-run with DELETE=1 to delete these rows."
    end
  end
end
