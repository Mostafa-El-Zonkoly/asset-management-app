# frozen_string_literal: true

module ApplicationHelper
  include Pagy::Frontend
  include Ransack::Helpers::FormHelper

  PNL_VALUE_KEYS = %i[unrealised_gain realised_gain total_gain total_dividends].freeze

  def pnl_class_for(value)
    return "text-slate-500" if value.nil?

    v = value.to_d
    return "text-slate-600 tabular-nums" if v.zero?

    v.positive? ? "text-emerald-800 tabular-nums font-semibold" : "text-red-600 tabular-nums font-semibold"
  rescue ArgumentError, TypeError
    "text-slate-700 tabular-nums"
  end

  def format_pnl_value(value, precision: 2)
    return tag.span("—", class: "text-slate-500") if value.nil?

    tag.span(number_with_precision(value.to_d, precision: precision), class: pnl_class_for(value))
  end

  def format_pnl_percent(value, precision: 2)
    return tag.span("—", class: "text-slate-500") if value.nil?

    num = value.to_d
    tag.span(class: pnl_class_for(num)) do
      "#{number_with_precision(num, precision: precision)}%".html_safe
    end
  end

  # Integer amount and rounded percentage, e.g. "1,000 (10%)" (no decimal places).
  def format_pnl_value_and_percent(amount, percent)
    return tag.span("—", class: "text-slate-500") if amount.nil?

    amt = amount.to_d.round
    pct_part =
      if percent.nil?
        ""
      else
        pct = percent.to_d.round
        " (#{number_with_precision(pct, precision: 0)}%)"
      end
    body = "#{number_with_precision(amt, precision: 0)}#{pct_part}"

    tag.span(body.html_safe, class: pnl_class_for(amt))
  end

  # Target / allocation deviation shown as a percentage (points or % vs amount).
  # Within ±1: blue (on track). Outside: green / red like gains (positive / negative).
  def format_target_deviation_percent(value, precision: 2)
    return tag.span("—", class: "text-slate-500") if value.nil?

    num = value.to_d
    css =
      if num.abs <= 1
        "text-blue-600 tabular-nums font-medium"
      else
        pnl_class_for(num)
      end
    tag.span(class: css) do
      "#{number_with_precision(num, precision: precision)}%".html_safe
    end
  end

  # deviation_pct: band for coloring (percentage points, or % vs target amount from service).
  # If deviation_pct is nil but target_amount is set, +amount+ is the currency deviation vs that target
  # and band = (deviation ÷ target) × 100.
  def format_target_deviation_value(amount, deviation_pct: nil, target_amount: nil, precision: 2)
    return tag.span("—", class: "text-slate-500") if amount.nil?

    band = deviation_pct
    if band.nil? && target_amount.present? && target_amount.to_d != 0
      band = (amount.to_d / target_amount.to_d) * 100
    end
    on_track = !band.nil? && band.to_f.abs <= 1.0
    css =
      if on_track
        "text-blue-600 tabular-nums font-medium"
      else
        pnl_class_for(amount)
      end
    tag.span(number_with_precision(amount.to_d, precision: precision), class: css)
  end

  # Per-row gain for the transactions table: buys use mark-to-market vs cash paid;
  # sells use recognised gain vs implied cost (proceeds − realised gain). Returns nil when N/A.
  def transaction_list_gain_percent(transaction, latest_price_in_asset_currency)
    return nil if transaction.asset.wallet?

    key = transaction.transaction_type&.key
    qty = transaction.quantity.to_d
    total = transaction.total_amount.to_d

    case key
    when "buy"
      return nil if latest_price_in_asset_currency.blank? || total <= 0 || qty <= 0

      mark = qty * latest_price_in_asset_currency.to_d
      ((mark - total) / total) * 100
    when "sell"
      rg = transaction.realised_gain
      return nil if rg.nil?

      basis = total - rg.to_d
      return nil if basis <= 0

      (rg.to_d / basis) * 100
    else
      nil
    end
  end

  def asset_select_label(asset)
    "#{asset.code} — #{asset.name}"
  end

  def format_stat_card_value(key, value, precision: 2)
    return tag.span("—", class: "text-slate-500") if value.nil?

    sym = key.to_sym
    if sym == :unrealised_gain_pct || key.to_s.end_with?("_pct")
      format_pnl_percent(value, precision: precision)
    elsif PNL_VALUE_KEYS.include?(sym)
      format_pnl_value(value, precision: precision)
    else
      tag.span(number_with_precision(value.to_d, precision: precision), class: "tabular-nums")
    end
  end
end
