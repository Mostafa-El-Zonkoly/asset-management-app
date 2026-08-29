# Lot Tracking & Purification (تطهير)

Design spec for the per-asset **operations** feature: FIFO tax-lot tracking of
buys/sells, plus quarterly Sharia **purification** list generation.

Status: **design agreed, not yet implemented.** This document is the reference
the implementation should follow.

---

## 1. Goal

For each asset in a portfolio, break the raw buy/sell history into discrete
**operations**:

- **Open operation** — a parcel of shares still held (with its own buy date).
- **Closed operation** — a parcel matched against a later sell, carrying a
  realized gain/loss.

…and, separately, produce a **purification (تطهير) list**: for every period a
parcel of shares was held, a line item the user marks *done / not-needed* and
into which they type the purification **amount** (the money is computed outside
the app — the app only produces *what* to purify).

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

### Worked example (purification, AAOIFI)

The 10 open shares from the 1 Jan lot, seen on **2 April**:

| Lot   | Quarter | Period       | Days | Qty | Status  |
|-------|---------|--------------|------|-----|---------|
| 1 Jan | 2026-Q1 | 1 Jan–31 Mar | ~90  | 10  | pending |
| 1 Jan | 2026-Q2 | 1 Apr–now    | accruing (not due until Q2 closes) |

No new lot is created when the quarter turns — the lot keeps accruing; a Q1
purification line is simply generated for it.

---

## 2. Decisions (agreed)

- **Matching:** FIFO (oldest lot first).
- **Coexistence:** the lot ledger runs **alongside** the existing average-cost
  `transactions.realised_gain`. Existing reports are untouched; lots are a new
  view. (Two realized-gain figures may appear — expected.)
- **Purification is per holding period, split by calendar quarter.** A holding
  wholly inside one quarter → one entry. A holding crossing quarters → one entry
  per quarter, prorated by **days held in that quarter**. Applies to shares
  later sold *and* still open.
- **Purification method is a portfolio-level setting:**
  - `aaoifi` — split by quarter, day-weighted (as above).
  - `sp` — **no** quarter split; one purification entry per lot for its whole
    holding period ("one pluck").
- **Purification value:** checklist (`done` / `not_required`) **plus a manually
  entered amount**. Calculation happens outside the app.
- **Quarters:** calendar quarters — Jan–Mar, Apr–Jun, Jul–Sep, Oct–Dec.
- **Quarter close is manual** (a button), not an automatic trigger.

---

## 3. Data model

New portfolio setting:

```
portfolios
  + purification_method : enum { aaoifi, sp }   default aaoifi
```

New tables:

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

purification_entries          # the "list to purify"
  portfolio_id, asset_id, asset_lot_id
  method : enum { aaoifi, sp }   # captured at generation time
  quarter : string             # e.g. "2026-Q1"  (null for sp)
  period_start : date
  period_end : date
  quantity : decimal           # shares this segment covers
  days : integer               # days held within the segment
  share_days : decimal         # Σ(qty × days) — precise basis for external calc
  status : enum { pending, done, not_required }  default pending
  amount : decimal             # entered manually
  done_on : date
  notes : text
  index: unique(asset_lot_id, quarter)   # (for sp, quarter is a sentinel e.g. "ALL")
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

### 4.2 Purification generation (manual "close quarter")

Never wipes user data — **upserts** by `(asset_lot_id, quarter)`, preserving
`status`, `amount`, `done_on`, `notes` for unchanged segments.

- **aaoifi:** for each lot, walk its share-count timeline (buys add, FIFO sells
  subtract), clip to each **completed** calendar quarter the lot had shares in,
  and compute `days` + `share_days` + representative `quantity` per quarter.
  One entry per `(lot, quarter)`.
- **sp:** one entry per lot spanning `opened_on → (fully-closed date or today)`,
  `quarter = "ALL"`, no split.

The **current, unfinished quarter** is shown as *accruing — not due* and is only
turned into a finalized entry once the user closes that quarter. "Close quarter"
finalizes every quarter up to the last fully-completed one.

---

## 5. v1 assumptions (change later if needed)

- **Day count:** inclusive of the buy date, exclusive of the sell date.
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
- In-app purification **amount** computation (rates/rules per asset).
- Specific-lot or LIFO matching.
- Corporate-action (split/merger) lot adjustments.
