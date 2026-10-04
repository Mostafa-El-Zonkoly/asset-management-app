# Lot Tracking & Purification (تطهير)

Design spec for the per-asset **operations** feature: FIFO tax-lot tracking of
buys/sells, plus quarterly Sharia **purification** list generation.

Status: lot ledger implemented. **Purification was redesigned on 2026-09-20** to
mirror the reference spreadsheet (`Stocks 6-9 2026.xlsx`): per-quarter rows, AAOIFI
+ S&P amounts computed from per-asset quarterly rates, per-purification paid flags.
Sections 1, 2, 3 (purification tables) and 4.2 below describe the new behaviour.

---

## 1. Goal

For each asset in a portfolio, break the raw buy/sell history into discrete
**operations**:

- **Open operation** — a parcel of shares still held (with its own buy date).
- **Closed operation** — a parcel matched against a later sell, carrying a
  realized gain/loss.

…and, separately, produce a **purification (تطهير) list**: for every quarter a
parcel of shares was held, a row with its **AAOIFI** purification (per share per
day) and — when it was sold at a profit — its **S&P** purification (percentage of
profit). Each of the two has a paid flag, and the screen shows total / paid /
outstanding.

### Worked example (buys/sells)

```
Buy  20 @ 1 Jan
Buy  20 @ 5 Jan
Sell 10 @ 6 Jan
Buy  10 @ 7 Jan
```

Produces:

| # | Operation | Qty | From | To    | Note                     |
|---|-----------|-----|------|-------|--------------------------|
| 1 | closed    | 10  | 1 Jan| 6 Jan | realized gain = x        |
| 2 | open      | 10  | 1 Jan| —     | remainder of the 1 Jan lot |
| 3 | open      | 20  | 5 Jan| —     |                          |
| 4 | open      | 10  | 7 Jan| —     |                          |

The 6 Jan sell consumes the **oldest** open lot first (FIFO): 10 of the 1 Jan
lot. 10 of that lot remain open.

### Worked example (purification)

Each purification **row** is a parcel of shares held during one calendar quarter
(one row of the spreadsheet). Take `Buy 100 @ 10 on 1 Aug`, `Sell 40 @ 12 on 20 Aug`,
seen in Q4 (say 3 Nov), with rates AAOIFI 0.01/share/day, S&P 5 %:

| Quarter | Row     | Qty | Held (inclusive)  | Days | AAOIFI           | S&P                         |
|---------|---------|-----|-------------------|------|------------------|-----------------------------|
| 2026-Q3 | closed  | 40  | 1 Aug – 20 Aug    | 20   | 40 × 20 × 0.01   | (12 − 10) × 40 × 5 %        |
| 2026-Q3 | ongoing | 60  | 1 Aug – 30 Sep    | 61   | 60 × 61 × 0.01   | —                           |
| 2026-Q4 | ongoing | 60  | 1 Oct – 31 Dec    | 92   | 60 × 92 × 0.01   | —                           |

* A partial sale splits the lot: the sold part is a **closed** row, the rest stays
  **ongoing**. Buy 100, buy 150, sell 200 → lot 1 closed (100); lot 2 splits into
  100 closed + 50 ongoing.
* Only ongoing rows carry into the next quarter; a closed row appears only in the
  quarters up to (and including) the quarter it was sold in.
* **AAOIFI** is charged on every row (every quarter the parcel is held).
* **S&P** is charged only on the closed row, only when the sale made a profit.

---

## 2. Decisions (agreed)

- **Matching:** FIFO (oldest lot first).
- **Coexistence:** the lot ledger runs **alongside** the existing average-cost
  `transactions.realised_gain`. Existing reports are untouched; lots are a new
  view. (Two realized-gain figures may appear — expected.)
- **Purification rows are per parcel per calendar quarter** (see the worked
  example). Both purifications are always computed; there is no per-portfolio
  method switch any more (`portfolios.purification_method` is now unused).
- **AAOIFI** = `quantity × days × per-day rate`. **S&P** = `(sell − buy) × quantity
  × percentage`, closed rows with a profit only.
- **Day count:** both ends inclusive — `1 + (min(sell, quarter end) − max(buy,
  quarter start))`, exactly as the spreadsheet. Ongoing rows run to the quarter end,
  so the running quarter is a projection that is recomputed when a sale is recorded.
- **Rates are entered per asset per quarter** (`purification_rates`): AAOIFI per
  share per day, and S&P percentage (stored as a percent, 4.25 = 4.25 %).
- **Each purification has its own paid flag** (AAOIFI paid, S&P paid). Statistics
  show total / paid / outstanding overall and per quarter, per currency.
- **Regeneration is automatic** (after any buy/sell via the transaction services,
  when rates are saved, and on first visit to the screen after a quarter rollover)
  and idempotent — a paid flag survives unless that purification's amount changes
  (then it is cleared, so it shows as outstanding again); rows the ledger no longer
  produces are deleted.
- **Quarters:** calendar quarters — Jan–Mar, Apr–Jun, Jul–Sep, Oct–Dec.
- **Quarter close is manual** (a button), not an automatic trigger.

---

## 3. Data model

`portfolios.purification_method` (aaoifi | sp) exists from the first design and is
now unused — both purifications are always computed.

Tables:

```
asset_lots                    # one row per BUY — the FIFO parcel
  portfolio_id, asset_id, currency_id
  buy_transaction_id          # FK to transactions (the opening buy) — stable identity
  opened_on : date
  buy_price_per_unit : decimal
  original_quantity : decimal
  remaining_quantity : decimal   # 0 = fully closed
  index: unique(buy_transaction_id)

lot_closures                  # one row per (lot ↔ sell) match — a CLOSED operation
  asset_lot_id
  sell_transaction_id         # FK to transactions (the sell)
  quantity : decimal          # units of this lot the sell consumed
  opened_on : date            # = lot.opened_on (denormalized for display)
  closed_on : date            # = sell date
  buy_price_per_unit : decimal
  sell_price_per_unit : decimal
  realised_gain : decimal     # (sell − buy) × quantity  (asset currency)
  index: unique(asset_lot_id, sell_transaction_id)

purification_entries          # one row per (lot, quarter, sale) — a spreadsheet row
  portfolio_id, asset_id, asset_lot_id
  sell_transaction_id          # NULL = ongoing row; set = closed (sold) row
  quarter : string             # "2026-Q3"
  period_start, period_end : date
  quantity, days
  buy_price_per_unit, sell_price_per_unit
  aaoifi_rate, aaoifi_amount   # per-day rate used, quantity x days x rate
  sp_rate, sp_amount           # percent used, profit x percent (closed rows only)
  aaoifi_paid, aaoifi_paid_on
  sp_paid, sp_paid_on
  notes
  index: unique(asset_lot_id, quarter) WHERE sell_transaction_id IS NULL
  index: unique(asset_lot_id, quarter, sell_transaction_id) WHERE NOT NULL

purification_rates            # "Totals & Purification" tab of the spreadsheet
  user_id, asset_id
  quarter : string
  aaoifi_per_day : decimal     # per share per day
  sp_percentage  : decimal     # percent of profit
  index: unique(asset_id, quarter)
```

Open operations are not a table — they are simply `asset_lots` with
`remaining_quantity > 0`.

---

## 4. Services

### 4.1 LotLedger rebuild (buys/sells → lots + closures)

Idempotent; safe to re-run after any transaction edit/delete.

For a given `(portfolio, asset)`:

1. Load buy & sell transactions ordered by `date, id`.
2. For each **buy** → upsert an `asset_lots` row keyed by `buy_transaction_id`
   (reset `remaining_quantity = original_quantity`).
3. Replay **sells** in order; each sell consumes open lots FIFO. For each slice
   consumed, upsert a `lot_closures` row keyed by `(asset_lot_id,
   sell_transaction_id)` and decrement the lot's `remaining_quantity`.
4. Delete stale closures no longer produced by the replay.

Hook: call after create/update/delete of a `buy`/`sell` transaction for that
asset+portfolio (the app already supports amending these — see
`FINANCIALLY_AMENDABLE_TYPE_KEYS`).

### 4.2 Purification generation

`LotLedger.generate_purifications!(portfolio_id, asset_id = nil)` — pure logic in
`LotLedger::Purification.compute` (no Rails; unit-tested against the spreadsheet's
47 rows). For every lot it walks each quarter from the buy quarter through the
current one: closures inside the quarter become closed rows, the remaining quantity
becomes one ongoing row. Rows are upserted by `(lot, quarter, sale)` so paid flags
are preserved; stale rows are deleted.

Backfill / regenerate everything: `bin/rails lot_ledger:purify`.

---

## 5. v1 assumptions (change later if needed)

- **Day count:** both ends inclusive (matches the spreadsheet). Superseded the
  earlier "exclusive of the sell date" convention.
- **`stock_dividend`** transactions create a **zero-cost lot**, so bonus shares
  flow through both FIFO matching and purification.
- **Splits** are out of scope for v1 (no split transaction type today).
- Realized gain is recorded in the **asset currency**; base-currency conversion
  can be layered on later using `exchange_rate_at_transaction`.
- Short/oversell (a sell with no open lots to match) is flagged, not silently
  allowed.

---

## 6. Out of scope (future)

- Automatic quarter-close scheduling.
- Fetching AAOIFI / S&P rates automatically (they are entered by hand per quarter).
- Partial payments (a paid flag is all-or-nothing per purification).
- Specific-lot or LIFO matching.
- Corporate-action (split/merger) lot adjustments.
