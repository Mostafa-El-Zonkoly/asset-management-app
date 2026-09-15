# frozen_string_literal: true

# Seed / refresh / backfill the official Egyptian market benchmarks (EGX30 and
# EGX33 Shariah Compliant Index). Benchmarks are ordinary MarketIndex rows flagged
# is_benchmark, fetched by the same price-fetch machinery as assets (see
# BenchmarkPriceFetcherService), so no separate model layer or job exists.
#
#   rake benchmarks:seed                 # idempotent create for every user
#   rake benchmarks:refresh              # fetch today's closing level now
#   rake "benchmarks:refresh[2026-09-10]"# fetch a specific date's level
#   rake "benchmarks:import_csv[EGX30,/path/close.csv]"  # backfill history (date,close)
#   rake benchmarks:list                 # show configured benchmarks + latest level
namespace :benchmarks do
  # Definition of each benchmark. `fetch_code` is the Mubasher index handle used to
  # build the fetch URL (.../indices/<fetch_code>/); `source_identifier` is the
  # explicit full URL (kept in sync here so either path fetches the same page).
  # Levels are large, thousands-grouped numbers — see Mubasher::IndexFetcher.
  DEFS = [
    {
      code: "EGX30",
      name: "EGX 30",
      source: "mubasher",
      fetch_code: "egx30",
      source_identifier: "https://www.mubasher.info/markets/EGX/indices/egx30/",
      index_kind: "price"
    },
    {
      code: "EGX33",
      name: "EGX 33 Shariah Compliant Index",
      source: "mubasher",
      fetch_code: "SHARIAH",
      source_identifier: "https://www.mubasher.info/markets/EGX/indices/SHARIAH/",
      index_kind: "price"
    }
  ].freeze

  desc "Create/repair the EGX30 and EGX33 Shariah benchmarks for every user (idempotent)"
  task seed: :environment do
    User.find_each do |user|
      Current.user = user
      currency = base_currency_for(user)
      unless currency
        warn "  [skip] #{user.email}: no EGP/base currency found"
        next
      end

      DEFS.each do |d|
        mi = MarketIndex.where(user_id: user.id).find_or_initialize_by(code: d[:code])
        mi.assign_attributes(
          name: d[:name],
          currency: currency,
          source: d[:source],
          fetch_code: d[:fetch_code],
          source_identifier: d[:source_identifier],
          index_kind: d[:index_kind],
          is_benchmark: true,
          is_active: true
        )
        mi.description ||= "Official Egyptian Exchange benchmark."
        mi.save!
        puts "  [ok] #{user.email}: #{mi.code} — #{mi.name}"
      end
    ensure
      Current.user = nil
    end
    puts "Done. 'Show benchmarks' on Portfolio Performance now overlays these."
  end

  desc "Fetch the latest (or given) closing level for every fetchable benchmark index"
  task :refresh, [:date] => :environment do |_t, args|
    date = args[:date].present? ? Date.parse(args[:date]) : Date.current
    # Current.user left nil => fetches every user's benchmarks (ownership on each
    # written IndexPrice is derived from its parent index).
    summary = BenchmarkPriceFetcherService.fetch_all(date: date) do |p|
      puts "  #{p[:current]}/#{p[:total]} #{p[:code]} (ok #{p[:success]}, failed #{p[:failed]})"
    end
    puts "Benchmark refresh #{date}: #{summary[:success]}/#{summary[:total]} ok, #{summary[:failed]} failed."
    summary[:results].reject { |r| r[:ok] }.each { |r| warn "  [fail] #{r[:code]}: #{r[:error]}" }
  end

  desc "Backfill historical closes from a CSV of 'date,close' rows for a benchmark code"
  task :import_csv, [:code, :path] => :environment do |_t, args|
    require "csv"
    code = args[:code].to_s
    path = args[:path].to_s
    raise "usage: rake \"benchmarks:import_csv[EGX30,/path/close.csv]\"" if code.empty? || path.empty?
    raise "file not found: #{path}" unless File.exist?(path)

    scraped = PriceSource.find_by(key: "scraped") ||
              PriceSource.create!(key: "scraped", label: "Scraped", position: PriceSource.maximum(:position).to_i + 1, active: true)

    total = 0
    # Import for every user that has this benchmark code (usually one).
    MarketIndex.unscoped.where(code: code, is_benchmark: true).find_each do |mi|
      count = 0
      CSV.foreach(path, headers: false) do |row|
        raw_date, raw_close = row
        next if raw_date.to_s.strip.casecmp?("date") # header line

        date = Date.parse(raw_date.to_s) rescue next
        close = BigDecimal(raw_close.to_s.delete(",")) rescue next
        rec = IndexPrice.unscoped.where(market_index_id: mi.id).find_or_initialize_by(date: date)
        rec.price = close
        rec.price_source = scraped
        rec.user_id ||= mi.user_id
        rec.save!
        count += 1
      end
      total += count
      puts "  #{mi.code} (user #{mi.user_id}): imported/updated #{count} closes"
    end
    puts "Imported #{total} index closes from #{path}."
  end

  desc "List configured benchmarks with their latest stored level"
  task list: :environment do
    MarketIndex.unscoped.where(is_benchmark: true).order(:user_id, :code).each do |mi|
      latest = IndexPrice.unscoped.where(market_index_id: mi.id).order(:date).last
      puts format("  user %-4s %-8s active=%-5s kind=%-13s latest=%s",
                  mi.user_id, mi.code, mi.is_active, mi.index_kind,
                  latest ? "#{latest.price} @ #{latest.date}" : "—")
    end
  end

  def base_currency_for(user)
    Currency.where(user_id: user.id, is_base: true).first ||
      Currency.where(user_id: user.id, code: "EGP").first ||
      Currency.where(user_id: user.id).order(:id).first
  end
end
