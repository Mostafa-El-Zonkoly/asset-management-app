# Portfolio App — Codebase Index

## What This App Does
A personal investment portfolio tracker. Users record transactions (buy, sell, dividends, deposits, withdrawals, transfers, deductions), track holdings and their cost basis, compute unrealised/realised gains, and view portfolio statistics and XIRR.

## Stack
- **Rails 7**, Ruby, PostgreSQL
- **Tailwind CSS** (JIT via Procfile.dev), Stimulus JS
- **Devise** for auth
- **Ransack** + **Pagy** for search/pagination
- **Docker** available (`docker-compose.yml`)

---

## Key Domain Models (`app/models/`)

| Model | Table | Notes |
|---|---|---|
| `Portfolio` | `portfolios` | Groups of holdings; has many `Holding` and `PortfolioTransaction` |
| `Asset` | `assets` | Stock, mutual fund, savings account, or wallet. `wallet?` scope identifies cash wallets |
| `Holding` | `holdings` | Current `quantity` + `average_buy_price` per portfolio/asset pair |
| `PortfolioTransaction` | `transactions` | Every financial event; belongs to `TransactionType`, `Currency`, optionally `Portfolio` |
| `TransactionType` | `transaction_types` | Lookup table. Keys: `buy`, `sell`, `cash_dividend`, `stock_dividend`, `deposit`, `withdrawal`, `transfer`, `deduction` |
| `Currency` | `currencies` | `Currency.reporting_currency_id` / `Currency.base.first` returns base currency |
| `AssetPrice` | `asset_prices` | Historical prices per asset/currency |
| `ExchangeRate` | `exchange_rates` | Historical FX rates |

**`PortfolioTransaction` constants (model):**
- `PORTFOLIO_REASSIGNABLE_TYPE_KEYS` — types where `portfolio_id` can be changed post-posting
- `FINANCIALLY_AMENDABLE_TYPE_KEYS` — types where qty/amount edits are supported

**Wallet-only types** (no `portfolio_id`): `deposit`, `withdrawal`, `transfer`  
**Portfolio types** (require `portfolio_id`): `buy`, `sell`, `cash_dividend`, `stock_dividend`, `deduction`

---

## Transaction Type Behaviour Summary

| Type | Holding effect | Wallet effect | Notes |
|---|---|---|---|
| `buy` | +qty, updates avg cost | debit wallet | Requires `related_wallet_id` |
| `sell` | -qty, records `realised_gain` | credit wallet | Requires `related_wallet_id` |
| `stock_dividend` | +qty at zero cost (dilutes avg) | none | `total_amount = 0` |
| `cash_dividend` | none | credit wallet | Requires `related_wallet_id` |
| `deposit` | none | credit wallet | Wallet-only |
| `withdrawal` | none | debit wallet | Wallet-only; checks balance |
| `transfer` | none | debit source, credit target | Creates 2 legs via `transfer_pair_id` |
| `deduction` | -qty, avg unchanged | none | `total_amount = 0`; no cash |

---

## Services (`app/services/`)

| Service | Purpose |
|---|---|
| `TransactionProcessorService` | Creates new transactions. Switch on `type.key`, calls `apply_<type>!`. Entry: `TransactionProcessorService.call!(attrs)` |
| `TransactionAmendService` | Edits existing transactions. Reverses then re-applies holdings. Entry: `TransactionAmendService.call!(transaction, attrs)` |
| `WalletLedgerService` | Computes wallet balances by summing `effect_on_wallet`. No DB state — derived from transactions |
| `HoldingsCalculatorService` | Computes unrealised/realised gain, cost basis (historical FX). `for_holding(holding)` → `Result` struct |
| `CurrencyConversionService` | `convert(amount, from_id, to_id)` and `rate_on_date(from_id, to_id, date)` |
| `PortfolioXirrService` | XIRR calculation per portfolio |
| `MonthlyCashFlowService` | Cash flow by month |
| `PortfolioStatsService` | Portfolio-level stats aggregation |
| `AssetStatsService` / `AssetSummaryService` | Per-asset stats |

### Adding a new transaction type — checklist:
1. `db/seeds.rb` — add to `seed_lookup(TransactionType, ...)`
2. `app/models/portfolio_transaction.rb` — add to constants as needed
3. `TransactionProcessorService` — add `when "key" then apply_key!` + `apply_key!` method
4. `TransactionAmendService` — add to `assert_row_valid!`, `validate_row_numbers!`, `reverse_holdings!`, `forward_holdings!` + helper methods
5. `HoldingsCalculatorService#historical_cost_in_base` — add type to replay if it affects qty
6. `WalletLedgerService#effect_on_wallet` — add if it touches a wallet

---

## Controllers (`app/controllers/`)

- `TransactionsController` — index/show/new/create/edit/update (no destroy)
- `AssetsController` — full CRUD + `compare`, `summary`, `performance`
- `PortfoliosController` — full CRUD + many collection analytics actions
- `Settings::` namespace — currencies, exchange rates, lookups, categories, etc.
- `Api::` namespace — JSON endpoints for chart data (portfolio performance, allocation, asset prices)

---

## Views (`app/views/`)

- Shared partials in `app/views/shared/` — `searchable_asset_field`, flash, etc.
- Layouts in `app/views/layouts/`
- No React/Vue — server-rendered ERB + Stimulus controllers

---

## Routes Highlights

```
root → dashboard#index
resources :portfolios    # /portfolios, with nested targets
resources :assets        # /assets, with compare/summary/performance
resources :transactions  # /transactions — index/show/new/create/edit/update only
resources :wallets       # /wallets — index only
namespace :settings      # /settings/lookups/:table for all lookup CRUD
namespace :api           # /api/portfolios/:id/performance etc.
```

---

## Database Notes

- Schema: `db/schema.rb`
- Migrations: `db/migrate/`
- Seeds: `db/seeds.rb` — all lookup data (asset types, sectors, transaction types, etc.). Uses `find_or_initialize_by` so safe to re-run.
- **To add a new lookup value**: add to `db/seeds.rb` and run `rails db:seed`.

---

## Key Patterns

- **Service objects**: `ServiceName.call!(args)` — raises `ServiceName::Error` on failure
- **Lookup models**: include `LookupRow` concern; have `key`, `label`, `position`, `active` columns
- **FX rates**: stored on `PortfolioTransaction.exchange_rate_at_transaction` at creation time; used for historical cost basis
- **Holdings**: derived from transactions via `TransactionProcessorService`; stored denormalised in `Holding` for performance
- **Wallet balances**: never stored — always computed from `WalletLedgerService.balance(wallet)`
