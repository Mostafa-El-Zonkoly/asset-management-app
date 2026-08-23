# Mubasher Fetcher (Portable)

This package gives you a **standalone Mubasher price fetcher** that you can copy to a new project and integrate quickly with Cursor.

## Files to Copy

- `lib/mubasher/fetcher.rb`
- `lib/mubasher/rails_adapter.rb` (only if your new project is Rails + ActiveRecord)

## Dependencies

Add these gems:

```ruby
gem "faraday"
gem "nokogiri"
```

Then run:

```bash
bundle install
```

## What It Supports

- Fetch price by Mubasher stock symbol (EGX path)
- Fetch price from a direct Mubasher URL (stocks/funds/custom)
- Multi-strategy extraction:
  - JSON-LD
  - common price/nav/value selectors
  - text around `h1`
  - raw HTML regex fallback
  - generic decimal fallback

## 1) Standalone Usage (Any Ruby Project)

```ruby
require_relative "lib/mubasher/fetcher"

fetcher = Mubasher::Fetcher.new

# Symbol-based
result = fetcher.fetch_stock_price(symbol: "ABUK")
# => { price: 62.76, source: "mubasher_symbol", fetched_at: "...", url: "...", ... }

# URL-based
result = fetcher.fetch_price_from_url(
  url: "https://www.mubasher.info/markets/EGX/stocks/ABUK"
)

puts result[:price]
```

## 2) Rails Integration (ActiveRecord)

Use `Mubasher::RailsAdapter` if you have:

- `Asset has_many :prices`
- `Price` with: `date`, `value`, `source`

Example:

```ruby
require Rails.root.join("lib/mubasher/rails_adapter")

asset = Asset.find(1)
record = Mubasher::RailsAdapter.new(asset: asset, date: Date.current).fetch_and_persist!
puts "Saved #{record.value} from #{record.source} on #{record.date}"
```

## Suggested Service Wrapper (New Project)

Create a project-level service that decides:

- if `asset.price_url` exists -> `fetch_price_from_url`
- else -> `fetch_stock_price(symbol: asset.symbol)`
- catches `Mubasher::FetchError` and logs cleanly

That keeps controllers/jobs clean.

## Cursor Integration Prompts (Copy/Paste)

Use these prompts in your new project:

### Prompt 1: install + wire

```text
I copied lib/mubasher/fetcher.rb and lib/mubasher/rails_adapter.rb.
Please:
1) ensure faraday and nokogiri are in Gemfile,
2) create a service app/services/mubasher_price_service.rb that fetches from asset.price_url or asset.symbol,
3) add a method to upsert price for date with source,
4) add specs for success + fetch failure + invalid URL.
```

### Prompt 2: controller endpoint

```text
Add POST /items/:id/fetch_mubasher_price
that fetches current price using MubasherPriceService and returns JSON:
{ success, price, source, date, error }.
Also add request specs.
```

### Prompt 3: background job

```text
Create FetchMubasherPricesJob to process all eligible assets:
- has price_url containing mubasher.info OR has symbol
- logs success/errors per asset
- does not stop on one failure.
Add a rake task to enqueue it.
```

## Notes / Caveats

- Mubasher page structure can change; parser uses layered fallbacks.
- Price extraction is heuristic; keep logs for bad parses.
- You can tighten `max_price` in calls if your market has known bounds.
- For production stability, add retry/backoff around network errors.

