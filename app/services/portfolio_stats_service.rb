# frozen_string_literal: true

class PortfolioStatsService
  class << self
    def summary(portfolio)
      new(portfolio).summary
    end

    def category_allocation(portfolio)
      new(portfolio).category_allocation
    end

    def management_style_allocation(portfolio)
      new(portfolio).management_style_allocation
    end

    # combined_total_value: sum of total_value for portfolios with include_in_combined_percent (for share % targets).
    def whole_portfolio_target_metrics(portfolio, combined_total_value: nil)
      new(portfolio).whole_portfolio_target_metrics(combined_total_value: combined_total_value)
    end

    # Total value (reporting ccy) of portfolios included in combined % / share-of-book denominators.
    def combined_percent_total_value
      Portfolio.where(include_in_combined_percent: true).inject(0.to_d) do |sum, p|
        sum + summary(p)[:total_value]
      end
    end

    def combined_percent_total_value_from_rows(rows)
      rows.select { |r| r[:portfolio].include_in_combined_percent }.sum { |r| r[:stats][:total_value].to_d }
    end

    # Normalize a portfolio_ids filter (array/scalar/nil) to a clean array of ints,
    # or nil when no filter is requested.
    def normalize_ids(portfolio_ids)
      return nil if portfolio_ids.blank?

      ids = Array(portfolio_ids).map { |x| x.to_i }.reject(&:zero?).uniq
      ids.presence
    end

    # Denominator for "% of included": the selected portfolios' total value when a
    # filter is active, otherwise all portfolios flagged include_in_combined_percent.
    def included_total_value(portfolio_ids = nil)
      ids = normalize_ids(portfolio_ids)
      return combined_percent_total_value if ids.nil?

      Portfolio.where(id: ids).inject(0.to_d) { |sum, p| sum + summary(p)[:total_value] }
    end

    # Sum of all active wallet balances converted to reporting currency (free cash).
    def total_wallet_balance_reporting
      base_id = Currency.reporting_currency_id
      return 0.to_d if base_id.blank?

      Asset.active.wallets.includes(:currency).inject(0.to_d) do |sum, w|
        bal = WalletLedgerService.balance(w)
        sum + CurrencyConversionService.convert(bal, w.currency_id, base_id)
      end
    end

    # Denominator for portfolio share % and whole-portfolio % targets: included investments + wallets.
    def wealth_total_for_share_percent(invested_total: nil)
      invested = invested_total.nil? ? combined_percent_total_value : invested_total.to_d
      invested + total_wallet_balance_reporting
    end

    # Aggregate wallet cash vs optional global target (% of wealth: included investments + wallets).
    def free_cash_target_metrics
      actual = total_wallet_balance_reporting
      wealth = wealth_total_for_share_percent
      actual_pct = wealth.nonzero? ? ((actual / wealth) * 100) : 0.to_d

      rec = FreeCashTarget.record
      tgt_pct = rec.target_percentage&.to_d

      h = {
        mode: :percentage,
        label: "Share of investments + wallets (included portfolios)",
        actual: actual.to_f,
        wealth: wealth.to_f,
        actual_pct: actual_pct.to_f,
        target_pct: nil,
        deviation_pct: nil,
        deviation_amount: nil
      }
      return h if tgt_pct.blank?

      deviation_pp = actual_pct - tgt_pct
      implied_value_at_target = wealth * (tgt_pct / 100.to_d)
      deviation_amt = actual - implied_value_at_target

      h[:target_pct] = tgt_pct.to_f
      h[:deviation_pct] = deviation_pp.to_f
      h[:deviation_amount] = deviation_amt.to_f
      h
    end

    def sector_breakdown(portfolio)
      new(portfolio).sector_breakdown
    end

    # Cross-portfolio sector analysis.
    # Returns rows grouped by sector for all assets that have a sector assigned.
    # Percentages:
    #   - pct_of_sectored: share of total value of all sectored assets (across all portfolios)
    #   - pct_of_included: share of total value of portfolios with include_in_combined_percent
    def cross_portfolio_sector_analysis(portfolio_ids = nil)
      by_sector = Hash.new(0.to_d)
      cost_by_sector = Hash.new(0.to_d)
      gain_by_sector = Hash.new(0.to_d)
      asset_ids_per_sector = Hash.new { |h, k| h[k] = Set.new }
      ids = normalize_ids(portfolio_ids)

      scope = Holding.joins(:asset).merge(Asset.active).includes(asset: [ :asset_type, :sector ])
      scope = scope.where(portfolio_id: ids) if ids
      scope.find_each do |h|
        next unless h.asset.direct_stock? && h.asset.sector_id.present?

        calc = HoldingsCalculatorService.for_holding(h)
        val = calc.current_value
        by_sector[h.asset.sector] += val
        cost_by_sector[h.asset.sector] += calc.cost_basis.to_d
        gain_by_sector[h.asset.sector] += calc.unrealised_gain.to_d
        asset_ids_per_sector[h.asset.sector] << h.asset_id
      end

      sectored_total = by_sector.values.sum
      included_total = included_total_value(portfolio_ids)

      by_sector.sort_by { |sector, _| sector.label }.map do |sector, value|
        pct_of_sectored = sectored_total.nonzero? ? ((value / sectored_total) * 100) : 0.to_d
        pct_of_included = included_total.nonzero? ? ((value / included_total) * 100) : 0.to_d
        cost = cost_by_sector[sector]
        gain = gain_by_sector[sector]
        gain_pct = cost.nonzero? ? ((gain / cost) * 100) : 0.to_d
        {
          sector: sector,
          value: value,
          asset_count: asset_ids_per_sector[sector].size,
          pct_of_sectored: pct_of_sectored,
          pct_of_included: pct_of_included,
          cost_basis: cost,
          unrealised_gain: gain,
          gain_pct: gain_pct
        }
      end
    end

    # Cross-portfolio sector → speciality breakdown.
    # Same filters as cross_portfolio_sector_analysis.
    # Returns a hash keyed by sector, each value being an array of speciality rows
    # plus a :_total row for the sector.
    def cross_portfolio_sector_speciality_analysis(portfolio_ids = nil)
      # accum[sector][speciality_or_nil] = value
      accum = Hash.new { |h, k| h[k] = Hash.new(0.to_d) }
      asset_ids = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = Set.new } }
      ids = normalize_ids(portfolio_ids)

      scope = Holding.joins(:asset).merge(Asset.active)
        .includes(asset: [ :asset_type, :sector, :speciality ])
      scope = scope.where(portfolio_id: ids) if ids
      scope.find_each do |h|
        next unless h.asset.direct_stock? && h.asset.sector_id.present?

        val = HoldingsCalculatorService.for_holding(h).current_value
        sector = h.asset.sector
        spec = h.asset.speciality
        accum[sector][spec] += val
        asset_ids[sector][spec] << h.asset_id
      end

      sectored_total = accum.values.map { |s| s.values.sum }.sum
      included_total = included_total_value(portfolio_ids)

      accum.sort_by { |sector, _| sector.label }.map do |sector, by_spec|
        sector_total = by_spec.values.sum
        pct_sector_of_sectored = sectored_total.nonzero? ? ((sector_total / sectored_total) * 100) : 0.to_d
        pct_sector_of_included = included_total.nonzero? ? ((sector_total / included_total) * 100) : 0.to_d

        speciality_rows = by_spec.sort_by { |spec, _| spec&.label || "zzz" }.map do |spec, value|
          pct_of_sector = sector_total.nonzero? ? ((value / sector_total) * 100) : 0.to_d
          pct_of_sectored = sectored_total.nonzero? ? ((value / sectored_total) * 100) : 0.to_d
          pct_of_included = included_total.nonzero? ? ((value / included_total) * 100) : 0.to_d
          {
            speciality: spec,
            value: value,
            asset_count: asset_ids[sector][spec].size,
            pct_of_sector: pct_of_sector,
            pct_of_sectored: pct_of_sectored,
            pct_of_included: pct_of_included
          }
        end

        {
          sector: sector,
          sector_total: sector_total,
          pct_of_sectored: pct_sector_of_sectored,
          pct_of_included: pct_sector_of_included,
          speciality_rows: speciality_rows
        }
      end
    end

    # Returns one row per holding (portfolio + asset) for a given sector,
    # optionally filtered to a specific speciality.
    # Each row includes current value and percentages vs sectored total and included-portfolios total.
    def sector_asset_detail(sector, speciality: nil, portfolio_ids: nil)
      ids = normalize_ids(portfolio_ids)
      included_total = included_total_value(portfolio_ids)

      # First pass: collect all sectored holdings to compute sectored total for denominators
      all_sectored_value = 0.to_d
      matching_holdings = []

      p1 = Holding.joins(:asset).merge(Asset.active)
        .includes(:portfolio, asset: [ :asset_type, :sector, :speciality, :currency ])
      p1 = p1.where(portfolio_id: ids) if ids
      p1.find_each do |h|
        next unless h.asset.direct_stock? && h.asset.sector_id == sector.id
        next if speciality && h.asset.speciality_id != speciality&.id

        r = HoldingsCalculatorService.for_holding(h)
        all_sectored_value += r.current_value
      end

      # Need true sectored total (all sectors) for pct_of_sectored
      full_sectored_total = 0.to_d
      p2 = Holding.joins(:asset).merge(Asset.active).includes(asset: :asset_type)
      p2 = p2.where(portfolio_id: ids) if ids
      p2.find_each do |h|
        next unless h.asset.direct_stock? && h.asset.sector_id.present?

        full_sectored_total += HoldingsCalculatorService.for_holding(h).current_value
      end

      # Second pass: build rows
      p3 = Holding.joins(:asset).merge(Asset.active)
        .includes(:portfolio, asset: [ :asset_type, :sector, :speciality, :currency ])
        .order("portfolios.name, assets.name")
      p3 = p3.where(portfolio_id: ids) if ids
      p3
        .select { |h| h.asset.direct_stock? && h.asset.sector_id == sector.id &&
                      (!speciality || h.asset.speciality_id == speciality&.id) }
        .map do |h|
        r = HoldingsCalculatorService.for_holding(h)
        val = r.current_value
        {
          holding: h,
          portfolio: h.portfolio,
          asset: h.asset,
          quantity: h.quantity,
          current_value: val,
          cost_basis: r.cost_basis,
          unrealised_gain: r.unrealised_gain,
          pct_of_filter: all_sectored_value.nonzero? ? ((val / all_sectored_value) * 100) : 0.to_d,
          pct_of_sectored: full_sectored_total.nonzero? ? ((val / full_sectored_total) * 100) : 0.to_d,
          pct_of_included: included_total.nonzero? ? ((val / included_total) * 100) : 0.to_d
        }
      end
    end

    # Aggregates all portfolios; all figures in reporting currency (via exchange rates).
    def overall_summary
      return empty_summary_hash if Portfolio.none?

      total_value = 0.to_d
      total_cost = 0.to_d
      unrealised = 0.to_d
      realised = 0.to_d

      Portfolio.find_each do |p|
        s = summary(p)
        total_value += s[:total_value]
        total_cost += s[:total_cost]
        unrealised += s[:unrealised_gain]
        realised += s[:realised_gain]
      end

      total_gain = unrealised + realised
      unreal_pct = total_cost.nonzero? ? ((unrealised / total_cost) * 100) : 0.to_d

      {
        total_value: total_value,
        total_cost: total_cost,
        unrealised_gain: unrealised,
        unrealised_gain_pct: unreal_pct,
        realised_gain: realised,
        total_gain: total_gain
      }
    end

    def summaries_by_portfolio
      Portfolio.order(:name).map { |p| { portfolio: p, stats: summary(p) } }
    end

    # One row per portfolio for the all-portfolios statistics page (values in reporting currency).
    def all_portfolios_detail_rows
      invested_included = combined_percent_total_value
      wealth = wealth_total_for_share_percent(invested_total: invested_included)
      Portfolio.includes(
        :whole_target_type,
        portfolio_targets: [ :category, :target_type ],
        portfolio_management_style_targets: [ :management_style, :target_type ]
      ).order(:name).map do |p|
        {
          portfolio: p,
          stats: summary(p),
          allocation: category_allocation(p),
          ms_allocation: management_style_allocation(p),
          whole: whole_portfolio_target_metrics(p, combined_total_value: wealth),
          targets: p.portfolio_targets.sort_by { |t| t.category.name },
          ms_targets: p.portfolio_management_style_targets.sort_by { |t| t.management_style.label }
        }
      end
    end

    # Currency codes used by non-wallet assets that lack a rate into reporting currency.
    def missing_fx_currency_codes_for_reporting
      base_id = Currency.reporting_currency_id
      return [] if base_id.blank?

      ccy_ids = Asset.active
        .joins(:asset_type)
        .distinct
        .pluck(:currency_id)
        .compact
        .uniq - [ base_id ]
      return [] if ccy_ids.empty?

      missing_ids = ccy_ids.select { |cid| CurrencyConversionService.rate_missing?(cid, base_id) }
      Currency.where(id: missing_ids).order(:code).pluck(:code)
    end

    def empty_summary_hash
      {
        total_value: 0.to_d,
        total_cost: 0.to_d,
        unrealised_gain: 0.to_d,
        unrealised_gain_pct: 0.to_d,
        realised_gain: 0.to_d,
        total_gain: 0.to_d
      }
    end
  end

  def initialize(portfolio)
    @portfolio = portfolio
  end

  def summary
    total_value = 0.to_d
    total_cost = 0.to_d
    unrealised = 0.to_d
    realised = 0.to_d

    base_id = Currency.reporting_currency_id

    @portfolio.holdings.includes(:asset).each do |h|
      next if h.asset.wallet?

      r = HoldingsCalculatorService.for_holding(h)
      total_value += r.current_value
      total_cost += r.cost_basis
      unrealised += r.unrealised_gain
    end

    @portfolio.portfolio_transactions.where.not(realised_gain: nil).find_each do |t|
      realised += if base_id.present?
        CurrencyConversionService.convert(t.realised_gain, t.currency_id, base_id)
      else
        t.realised_gain.to_d
      end
    end
    realised += portfolio_dividends_reporting(base_id)

    total_gain = unrealised + realised
    unreal_pct = total_cost.nonzero? ? ((unrealised / total_cost) * 100) : 0.to_d

    {
      total_value: total_value,
      total_cost: total_cost,
      unrealised_gain: unrealised,
      unrealised_gain_pct: unreal_pct,
      realised_gain: realised,
      total_gain: total_gain
    }
  end

  def portfolio_dividends_reporting(base_id)
    type = TransactionType.find_by(key: "cash_dividend")
    return 0.to_d unless type

    @portfolio.portfolio_transactions.where(transaction_type: type).sum do |t|
      if base_id.present?
        CurrencyConversionService.convert(t.total_amount, t.currency_id, base_id)
      else
        t.total_amount.to_d
      end
    end
  end

  def category_allocation
    by_category = Hash.new(0.to_d)
    @portfolio.holdings.includes(asset: :category).each do |h|
      next if h.asset.wallet?

      by_category[h.asset.category] += HoldingsCalculatorService.for_holding(h).current_value
    end

    targets_by_cat = @portfolio.portfolio_targets.includes(:target_type, :category).index_by(&:category_id)
    categories = (by_category.keys | targets_by_cat.values.map(&:category)).uniq.sort_by(&:name)
    sum = by_category.values.sum

    categories.map do |category|
      value = by_category[category] || 0.to_d
      tgt = targets_by_cat[category.id]
      actual_pct = sum.nonzero? ? ((value / sum) * 100) : 0.to_d

      target_pct = nil
      target_amount = nil
      deviation_pct = nil
      deviation_amount = nil
      static_achieved_pct = nil

      if tgt
        case tgt.target_type.key
        when "percentage"
          target_pct = tgt.target_percentage&.to_d
          deviation_pct = (actual_pct - target_pct) if target_pct
        when "static_amount"
          target_amount = tgt.target_amount&.to_d
          if target_amount.present?
            deviation_amount = value - target_amount
            static_achieved_pct = target_amount.positive? ? ((value / target_amount) * 100) : nil
          end
        end
      end

      {
        category_id: category.id,
        category: category.name,
        value: value.to_f,
        target_pct: target_pct&.to_f,
        actual_pct: actual_pct.to_f,
        target_amount: target_amount&.to_f,
        deviation_pct: deviation_pct&.to_f,
        deviation_amount: deviation_amount&.to_f,
        static_achieved_pct: static_achieved_pct&.to_f,
        deviation: deviation_pct&.to_f
      }
    end
  end

  # Mutual fund holdings only, grouped by management style (passive / active).
  # Mix % uses the same denominator as category allocation: total non-wallet portfolio value.
  def management_style_allocation
    by_style = Hash.new(0.to_d)
    sum = 0.to_d
    @portfolio.holdings.includes(asset: [ :asset_type, :management_style ]).each do |h|
      next if h.asset.wallet?

      val = HoldingsCalculatorService.for_holding(h).current_value
      sum += val
      next unless h.asset.mutual_fund?
      next if h.asset.management_style_id.blank?

      by_style[h.asset.management_style] += val
    end

    targets_by_style = @portfolio.portfolio_management_style_targets.includes(:target_type, :management_style).index_by(&:management_style_id)
    styles = (by_style.keys | targets_by_style.values.map(&:management_style)).uniq.sort_by(&:label)

    styles.map do |style|
      value = by_style[style] || 0.to_d
      tgt = targets_by_style[style.id]
      actual_pct = sum.nonzero? ? ((value / sum) * 100) : 0.to_d

      target_pct = nil
      target_amount = nil
      deviation_pct = nil
      deviation_amount = nil
      static_achieved_pct = nil

      if tgt
        case tgt.target_type.key
        when "percentage"
          target_pct = tgt.target_percentage&.to_d
          deviation_pct = (actual_pct - target_pct) if target_pct
        when "static_amount"
          target_amount = tgt.target_amount&.to_d
          if target_amount.present?
            deviation_amount = value - target_amount
            static_achieved_pct = target_amount.positive? ? ((value / target_amount) * 100) : nil
          end
        end
      end

      {
        management_style_id: style.id,
        management_style: style.label,
        value: value.to_f,
        target_pct: target_pct&.to_f,
        actual_pct: actual_pct.to_f,
        target_amount: target_amount&.to_f,
        deviation_pct: deviation_pct&.to_f,
        deviation_amount: deviation_amount&.to_f,
        static_achieved_pct: static_achieved_pct&.to_f,
        deviation: deviation_pct&.to_f
      }
    end
  end

  # Optional whole-portfolio goal on {Portfolio} (reporting-currency values for amounts).
  # combined_total_value: pass sum of included portfolios' values to avoid recomputing; nil = compute.
  def whole_portfolio_target_metrics(combined_total_value: nil)
    return nil if @portfolio.whole_target_type_id.blank?

    stats = summary
    tv = stats[:total_value]

    case @portfolio.whole_target_type.key
    when "percentage"
      overall = combined_total_value
      overall = self.class.wealth_total_for_share_percent if overall.nil?
      actual_pct = overall.nonzero? ? ((tv / overall) * 100) : 0.to_d
      tgt = @portfolio.whole_target_percentage&.to_d
      return nil if tgt.blank?

      deviation_pct = (actual_pct - tgt)
      implied_value_at_target = overall * (tgt / 100.to_d)
      deviation_amount = tv - implied_value_at_target

      {
        mode: :percentage,
        label: "Share of investments + wallets (included portfolios)",
        actual_pct: actual_pct.to_f,
        target_pct: tgt.to_f,
        deviation_pct: deviation_pct.to_f,
        deviation_amount: deviation_amount.to_f
      }
    when "static_amount"
      tgt = @portfolio.whole_target_amount&.to_d
      return nil if tgt.blank?

      achieved_pct = tgt.positive? ? ((tv / tgt) * 100) : nil
      deviation_amount = tv - tgt
      deviation_pct = tgt.nonzero? ? ((deviation_amount / tgt) * 100) : nil

      {
        mode: :static_amount,
        label: "Total portfolio value",
        actual_amount: tv.to_f,
        target_amount: tgt.to_f,
        deviation_amount: deviation_amount.to_f,
        deviation_pct: deviation_pct&.to_f,
        achieved_pct: achieved_pct&.to_f
      }
    else
      nil
    end
  end

  def sector_breakdown
    totals = Hash.new(0.to_d)
    @portfolio.holdings.includes(asset: [ :sector, :category ]).each do |h|
      next unless h.asset.direct_stock?
      next if h.asset.sector.blank?

      r = HoldingsCalculatorService.for_holding(h)
      totals[h.asset.sector.label] += r.current_value
    end

    sum = totals.values.sum
    totals.map do |label, value|
      pct = sum.nonzero? ? ((value / sum) * 100) : 0.to_d
      { sector: label, value: value.to_f, pct: pct.to_f }
    end
  end
end
