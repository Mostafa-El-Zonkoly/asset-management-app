# frozen_string_literal: true

require "bigdecimal"

# "Managed Wealth" value + external-flow series for ONE portfolio, used by the
# Wealth Return view of PortfolioPerformanceService (basis: :wealth).
#
#   Managed Wealth(d) = holdings market value(d)        (same series Invested TWR uses)
#                     + retained cash(d)
#
# Where the cash comes from (in order of preference):
#
#   1. The portfolio's LIQUIDITY WALLET (portfolios.liquidity_wallet_id, optional).
#      cash(d) = that wallet's balance on d, replayed from the wallet ledger. The ledger
#      is complete from the first transaction, so no opening-capital baseline is needed.
#   2. Otherwise the portfolio's own cash ledger (opening cash + buy/sell/dividend/
#      deduction effects + PortfolioCashFlow rows), anchored at the migration date.
#
# External vs internal (wallet scope = this portfolio + its liquidity wallet W):
#   internal  buy/sell/cash dividend of THIS portfolio settled through W, and
#             PortfolioCashFlow contribution/withdrawal between this portfolio and W
#             (they only move value between holdings and cash).
#   external  wallet deposits/withdrawals on W, wallet transfers in/out of W, other
#             portfolios' trades or cash moves that use W, and this portfolio's own buys/
#             sells settled through some OTHER wallet (money crossing the boundary).
# Only external flows are neutralised by the return engine. Wallets of two selected
# portfolios that exchange money cancel arithmetically in "All portfolios".
#
# Starting wealth enters as an external "opening capital" flow on the first date (earlier
# flows are dropped), so a portfolio that appears part-way through a combined series cannot
# create an artificial jump.
#
# Availability (never fabricate): N/A with a reason when a role filter is active, there is
# neither a liquidity wallet nor an opening-capital baseline, or there is no valuation
# axis. If cash turns negative on some date the series stays valid UP TO THE DAY BEFORE and
# `through` records that last good date (later periods are N/A in the table).
class PortfolioWealthSeriesService
  EPOCH = Date.new(1900, 1, 1)

  Series = Struct.new(:values, :cash_values, :flows, :start, :reason, :detail, :through, :source, :internal, keyword_init: true) do
    def available?
      reason.nil? && values.present?
    end

    def truncated?
      !through.nil?
    end
  end

  REASON_TEXT = {
    role_filter: "cash is not attributed to position roles (use role = All)",
    not_migrated: "no liquidity wallet is assigned and no opening-capital baseline is set, so cash history cannot be reconstructed",
    no_history: "no trade or cash history",
    before_migration: "no holdings valuation on/after the migration date",
    negative_cash: "cash goes negative (a buy was not funded), so cash history is unreliable"
  }.freeze

  # Wallet-ledger effect kinds that are internal to a portfolio when that portfolio's own:
  # they only move value between holdings and the liquidity wallet.
  INTERNAL_KINDS = %w[buy sell cash_dividend].freeze

  # PortfolioCashFlow rows between THIS portfolio and ITS OWN liquidity wallet. They move
  # money from one place inside the managed universe (the wallet) to another (the
  # portfolio's own cash ledger), so they change neither Managed Wealth nor the external
  # capital. Previously they were replayed as an internal cash DRAIN with no offsetting
  # asset, so every contribution that was not spent in the same instant looked like a
  # loss (the "deposit collapses the chart" bug). They are now dropped from both the cash
  # and the flow streams.
  OWN_WALLET_TRANSFER_KINDS = %w[contribution cash_withdrawal].freeze

  class << self
    def call(portfolio, role: "all", base_id: nil)
      new(portfolio, role: role, base_id: base_id).call
    end

    # Pure core: combine a holdings value series with a cash ledger.
    #   holdings_values: [[Date, BigDecimal], ...] ascending
    #   ledger:          PortfolioCashLedger
    # Returns a Series (available or with a reason). No DB access.
    def compose(holdings_values, ledger, source: :portfolio_cash)
      start_on = ledger.migration_on
      # Valuation dates must be strictly ascending and unique: the return engine chains
      # day after day, so an out-of-order point would turn into a fake jump.
      held = holdings_values.select { |d, _v| d >= start_on }.sort_by(&:first).uniq(&:first)
      return unavailable(:before_migration) if held.empty?

      through = nil
      bad = ledger.first_negative_date(held.map(&:first))
      if bad
        held = held.select { |d, _v| d < bad }
        return unavailable(:negative_cash, "first on #{bad.iso8601}") if held.size < 2

        through = held.last[0]
      end

      values = []
      cash_values = []
      internal = {}
      prev_d = nil
      held.each do |d, h|
        c = ledger.cash_on(d)
        values << [d, h.to_d + c]
        cash_values << [d, c]
        internal[d] = ledger.internal_between(prev_d, d) # diagnostics (PerformanceDebugLog)
        prev_d = d
      end

      first_date = values.first[0]
      flows = Hash.new { |hash, k| hash[k] = PortfolioCashFlowService::Day.new(external: 0.to_d, dividend: 0.to_d) }
      # Starting wealth enters the scope as capital on the first date...
      flows[first_date].external += values.first[1]
      # ...and only LATER external flows are performance-neutralised.
      ledger.external_flows_by_day.each do |d, amt|
        next if d <= first_date || (through && d > through)

        flows[d].external += amt
      end

      Series.new(values: values, cash_values: cash_values, flows: flows, start: first_date,
                 reason: nil, detail: through ? "valid through #{through.iso8601}" : nil,
                 through: through, source: source, internal: internal)
    end

    # Pure: split wallet-ledger effects into the ledger's two event streams.
    #   effects: [{ date:, amount:, kind:, portfolio_id: }]  signed effect ON the wallet
    #   elsewhere: [{ date:, amount: }]  this portfolio's own buys(+)/sells(-) that did NOT
    #                                    go through the wallet (external boundary crossings)
    # => { tx_events: internal (cash), flow_events: external (cash), boundary_events: external (no cash) }
    def wallet_events(effects, portfolio_id, elsewhere = [])
      tx = []
      flow = []
      effects.each do |e|
        own = e[:portfolio_id] == portfolio_id
        next if own && OWN_WALLET_TRANSFER_KINDS.include?(e[:kind]) # wealth-neutral, see above

        internal = own && INTERNAL_KINDS.include?(e[:kind])
        (internal ? tx : flow) << [e[:date], e[:amount].to_d]
      end
      boundary = elsewhere.map { |e| [e[:date], e[:amount].to_d] }
      { tx_events: tx, flow_events: flow, boundary_events: boundary }
    end

    # Pure: a valuation axis for a portfolio with no holdings (cash only): market dates on/after
    # the first cash event, else the event dates themselves.
    def cash_only_axis(event_dates, market_dates)
      return [] if event_dates.empty?

      first = event_dates.min
      dates = market_dates.select { |d| d >= first }
      dates = event_dates if dates.empty?
      dates.uniq.sort
    end

    def unavailable(reason, detail = nil)
      Series.new(values: [], cash_values: [], flows: {}, start: nil, reason: reason, detail: detail, through: nil, source: nil)
    end

    def reason_text(series)
      return nil if series.nil? || series.reason.nil?

      [REASON_TEXT[series.reason], series.detail].compact.join(" — ")
    end
  end

  def initialize(portfolio, role:, base_id:)
    @portfolio = portfolio
    @role = role.to_s
    @base_id = base_id || Currency.reporting_currency_id
  end

  def call
    return self.class.unavailable(:role_filter) unless @role == "all"

    wallet = liquidity_wallet
    return wallet_series(wallet) if wallet

    opening = @portfolio.opening_capital
    return self.class.unavailable(:not_migrated) if opening.nil?

    holdings = PortfolioValueSeriesService.call(@portfolio, role: "all", base_id: @base_id)
    return self.class.unavailable(:no_history) if holdings.values.blank?

    ledger = PortfolioCashLedger.new(
      opening_cash: reporting(opening.opening_cash, opening.currency_id),
      migration_on: opening.migration_on,
      tx_events: tx_events(opening.migration_on),
      flow_events: flow_events
    )
    self.class.compose(holdings.values, ledger)
  end

  private

  # Tolerates the column not being migrated yet.
  def liquidity_wallet
    return nil unless @portfolio.respond_to?(:has_attribute?) && @portfolio.has_attribute?(:liquidity_wallet_id)

    @portfolio.liquidity_wallet
  end

  # ---- Liquidity-wallet scope ----------------------------------------------
  def wallet_series(wallet)
    effects = wallet_effects(wallet)
    elsewhere = trades_outside_wallet(wallet)
    holdings = PortfolioValueSeriesService.call(@portfolio, role: "all", base_id: @base_id)
    values = holdings.values
    event_dates = (effects.map { |e| e[:date] } + elsewhere.map { |e| e[:date] })
    if values.blank?
      axis = self.class.cash_only_axis(event_dates, AssetPrice.distinct.order(:date).pluck(:date))
      return self.class.unavailable(:no_history) if axis.empty?

      values = axis.map { |d| [d, 0.to_d] }
    end

    ev = self.class.wallet_events(effects, @portfolio.id, elsewhere)
    ledger = PortfolioCashLedger.new(opening_cash: 0.to_d, migration_on: EPOCH, tx_events: ev[:tx_events],
                                 flow_events: ev[:flow_events], boundary_events: ev[:boundary_events])
    self.class.compose(values, ledger, source: :liquidity_wallet)
  end

  # Signed effect on the wallet of everything that touches it, tagged with kind + portfolio.
  def wallet_effects(wallet)
    effects = []
    WalletLedgerService.transactions_touching_wallet(wallet.id).each do |t|
      amt = WalletLedgerService.effect_on_wallet(t, wallet.id).to_d
      next if amt.zero?

      effects << { date: t.date.to_date, amount: reporting(amt, wallet.currency_id), kind: t.transaction_type.key, portfolio_id: t.portfolio_id }
    end
    PortfolioCashFlow.where(related_wallet_id: wallet.id, kind: %w[contribution withdrawal]).each do |f|
      signed = f.kind == "contribution" ? -f.amount.to_d : f.amount.to_d # wallet -> portfolio drains the wallet
      effects << { date: f.occurred_at.to_date, amount: reporting(signed, f.currency_id),
                   kind: f.kind == "contribution" ? "contribution" : "cash_withdrawal", portfolio_id: f.portfolio_id }
    end
    effects
  end

  # This portfolio's buys(+)/sells(-) settled through another wallet (or none): the holdings
  # value moves but the liquidity wallet does not, so it is a boundary crossing.
  def trades_outside_wallet(wallet)
    @portfolio.portfolio_transactions
              .joins(:transaction_type)
              .includes(:transaction_type, :asset)
              .where(transaction_types: { key: %w[buy sell] })
              .reject { |t| t.related_wallet_id == wallet.id || t.asset&.wallet? }
              .map do |t|
      amt = reporting(t.total_amount, t.currency_id)
      { date: t.date.to_date, amount: t.transaction_type.key == "buy" ? amt : -amt }
    end
  end

  # ---- Portfolio-cash scope (no liquidity wallet) ----------------------------
  # Same cash-moving transaction types and signs as PortfolioAccountingService, so the
  # ledger reconciles to PortfolioAccountingService#cash at the latest date.
  def tx_events(migration_on)
    signs = PortfolioAccountingService::CASH_TX_SIGN
    @portfolio.portfolio_transactions
              .joins(:transaction_type)
              .includes(:transaction_type)
              .where(transaction_types: { key: signs.keys })
              .where("transactions.date > ?", migration_on.end_of_day)
              .map { |tx| [tx.date.to_date, reporting(tx.total_amount, tx.currency_id) * signs[tx.transaction_type.key]] }
  end

  def flow_events
    @portfolio.portfolio_cash_flows.map do |f|
      [f.occurred_at.to_date, reporting(f.amount, f.currency_id) * f.cash_sign]
    end
  end

  def reporting(amount, currency_id)
    a = amount.to_d
    return a if @base_id.blank? || currency_id.nil? || currency_id == @base_id

    CurrencyConversionService.convert(a, currency_id, @base_id).to_d
  rescue StandardError
    amount.to_d
  end
end
