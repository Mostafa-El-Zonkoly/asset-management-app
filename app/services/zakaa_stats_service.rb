# frozen_string_literal: true

# Zakatable wealth across all portfolios + wallets; eligibility vs configured nisab.
class ZakaaStatsService
  Row = Struct.new(
    :asset,
    :current_value,
    :zaka_percentage,
    :zakatable_amount,
    :quantity,
    :portfolio_names,
    :type_descriptor,
    keyword_init: true
  )

  class << self
    def call
      new.call
    end

    def missing_fx_currency_codes_for_reporting
      PortfolioStatsService.missing_fx_currency_codes_for_reporting
    end
  end

  def call
    reporting = Currency.base.first
    base_id = Currency.reporting_currency_id
    settings = ZakaSetting.record
    nisab = ZakaaNisabService.call(settings: settings, reporting_currency_id: base_id)

    rows = build_rows(base_id)
    zakatable_total = rows.sum { |r| r.zakatable_amount.to_d }

    eligible, eligibility_reason = eligibility_for(zakatable_total, nisab)

    rate = settings.rate_percentage&.to_d
    suggested_due =
      if eligible && rate.present? && rate.positive?
        zakatable_total * (rate / 100.to_d)
      end

    last_payment = ZakaPayment.latest
    days_since =
      if last_payment
        (Date.current - last_payment.paid_on).to_i
      end

    interval = settings.payment_interval_days
    payment_overdue =
      last_payment.present? &&
      days_since.present? &&
      interval.present? &&
      days_since > interval

    {
      rows: rows,
      zakatable_total: zakatable_total,
      nisab: nisab,
      nisab_threshold: nisab.threshold,
      eligible: eligible,
      eligibility_reason: eligibility_reason,
      suggested_due: suggested_due,
      rate_percentage: rate,
      last_payment: last_payment,
      days_since_last_payment: days_since,
      payment_interval_days: interval,
      payment_overdue: payment_overdue,
      settings: settings,
      reporting_currency: reporting,
      missing_fx_codes: self.class.missing_fx_currency_codes_for_reporting
    }
  end

  private

  def build_rows(base_id)
    investment_rows = investment_asset_rows(base_id)
    wallet_rows = wallet_asset_rows(base_id)
    (investment_rows + wallet_rows).sort_by { |r| r.asset.code.downcase }
  end

  def investment_asset_rows(base_id)
    holdings_scope = Holding.joins(asset: :asset_type).merge(Asset.active).where("holdings.quantity > 0")
      .where.not(asset_types: { key: "wallet" })
      .includes(:portfolio, asset: %i[asset_type currency stock_purpose sector speciality
                                      fund_type fund_style management_style market_index])
    grouped = holdings_scope.group_by(&:asset_id)

    grouped.filter_map do |_asset_id, hs|
      asset = hs.first.asset
      calcs = hs.map { |h| HoldingsCalculatorService.for_holding(h) }
      current_value = calcs.sum(&:current_value)
      next if current_value.to_d <= 0

      build_row(
        asset: asset,
        current_value: current_value,
        quantity: hs.sum { |h| h.quantity.to_d },
        portfolio_names: hs.map { |h| h.portfolio.name }.uniq.sort.join(", ")
      )
    end
  end

  def wallet_asset_rows(base_id)
    return [] if base_id.blank?

    Asset.active.wallets.includes(:currency, :asset_type).filter_map do |wallet|
      bal = WalletLedgerService.balance(wallet)
      next if bal.to_d <= 0

      current_value = CurrencyConversionService.convert(bal, wallet.currency_id, base_id)
      next if current_value.to_d <= 0

      build_row(
        asset: wallet,
        current_value: current_value,
        quantity: bal,
        portfolio_names: "Wallet"
      )
    end
  end

  def build_row(asset:, current_value:, quantity:, portfolio_names:)
    pct = asset.zaka_percentage.to_d
    zakatable = current_value.to_d * (pct / 100.to_d)

    Row.new(
      asset: asset,
      current_value: current_value.to_d,
      zaka_percentage: pct,
      zakatable_amount: zakatable,
      quantity: quantity,
      portfolio_names: portfolio_names,
      type_descriptor: type_descriptor_for(asset)
    )
  end

  def eligibility_for(zakatable_total, nisab)
    unless nisab.configured
      return [ false, :nisab_not_configured ]
    end
    if nisab.missing_price
      return [ false, :nisab_price_missing ]
    end
    if nisab.threshold.nil?
      return [ false, :nisab_unavailable ]
    end

    if zakatable_total >= nisab.threshold
      [ true, :above_nisab ]
    else
      [ false, :below_nisab ]
    end
  end

  def type_descriptor_for(asset)
    parts = []
    parts << asset.asset_type&.label
    parts << asset.stock_purpose&.label
    parts << asset.sector&.label
    parts << asset.speciality&.label
    parts << asset.fund_type&.label
    parts << asset.fund_style&.label
    parts << asset.management_style&.label
    parts << asset.market_index&.code
    parts.compact.map(&:presence).compact.join(" - ")
  end
end
