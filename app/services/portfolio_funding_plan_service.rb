# frozen_string_literal: true

class PortfolioFundingPlanService
  AllocationResult = Struct.new(:rows, :allocated_total, :remaining, keyword_init: true)

  class << self
    def build(amount:)
      new(amount: amount).build
    end
  end

  def initialize(amount:)
    @amount = amount.to_d
  end

  def build
    top_level_rows = base_top_level_rows
    top_level_rows = with_projected_capacity_gaps(top_level_rows, total_add: @amount)
    top_level_allocation = allocate_top_level_rows(top_level_rows)
    rows_with_percentages = with_value_percentages(top_level_allocation.rows, allocated_total: @amount)

    rows_with_target_breakdowns = rows_with_percentages.map do |row|
      next row unless row[:kind] == :portfolio

      target_breakdown = allocate_targets(row[:portfolio], row[:suggested_add].to_d)
      row.merge(target_breakdown: target_breakdown)
    end
    rows_with_target_breakdowns = with_top_level_post_add_deviations(
      rows_with_target_breakdowns,
      allocated_total: @amount
    )

    {
      amount: @amount,
      allocated_total: top_level_allocation.allocated_to_portfolios,
      unallocated_amount: [@amount - top_level_allocation.allocated_to_portfolios, 0.to_d].max,
      rows: rows_with_target_breakdowns
    }
  end

  private

  def base_top_level_rows
    rows = targeted_portfolio_rows
    wallet = wallets_row
    rows << wallet if wallet
    rows
  end

  def targeted_portfolio_rows
    wealth = PortfolioStatsService.wealth_total_for_share_percent

    Portfolio.order(:name).filter_map do |portfolio|
      next nil unless portfolio.include_in_combined_percent

      stats = PortfolioStatsService.summary(portfolio)
      whole = PortfolioStatsService.whole_portfolio_target_metrics(
        portfolio,
        combined_total_value: wealth
      )
      next nil if whole.blank?

      {
        kind: :portfolio,
        name: portfolio.name,
        portfolio: portfolio,
        current_value: stats[:total_value].to_d,
        whole_target: whole,
        capacity_gap: 0.to_d,
        suggested_add: 0.to_d
      }
    end
  end

  def wallets_row
    metrics = PortfolioStatsService.free_cash_target_metrics
    return nil if metrics.blank?

    {
      kind: :wallet,
      name: "Free cash wallets",
      current_value: metrics[:actual].to_d,
      whole_target: metrics,
      capacity_gap: 0.to_d,
      suggested_add: 0.to_d
    }
  end

  def with_projected_capacity_gaps(rows, total_add:)
    projected_total = rows.sum { |row| row[:current_value].to_d } + total_add.to_d

    rows.map do |row|
      gap = projected_capacity_gap_for_row(row, projected_total)
      row.merge(capacity_gap: gap)
    end
  end

  def allocate_top_level_rows(rows)
    portfolio_rows = rows.select { |row| row[:kind] == :portfolio }
    wallet_row = rows.find { |row| row[:kind] == :wallet }
    projected_total = rows.sum { |row| row[:current_value].to_d } + @amount
    gap_total = portfolio_rows.sum { |row| row[:capacity_gap].to_d }
    max_with_wallet = @amount + max_wallet_redistributable(wallet_row, projected_total)
    allocatable_for_portfolios = portfolio_allocatable_for_portfolios(
      wallet_row,
      projected_total: projected_total,
      gap_total: gap_total,
      max_with_wallet: max_with_wallet
    )

    portfolio_allocation = allocate_with_caps(allocatable_for_portfolios, portfolio_rows) { |row| row[:capacity_gap] }
    allocated_to_portfolios = portfolio_allocation.allocated_total
    wallet_suggested_add = @amount - allocated_to_portfolios

    rows_by_kind = portfolio_allocation.rows.each_with_object({}) do |row, memo|
      memo[[row[:kind], row[:name]]] = row
    end
    if wallet_row
      rows_by_kind[[wallet_row[:kind], wallet_row[:name]]] = wallet_row.merge(suggested_add: wallet_suggested_add)
    end

    allocated_rows = rows.map { |row| rows_by_kind.fetch([row[:kind], row[:name]], row) }
    Struct.new(:rows, :allocated_to_portfolios, keyword_init: true).new(
      rows: allocated_rows,
      allocated_to_portfolios: allocated_to_portfolios
    )
  end

  # How much can flow to portfolios in total (new cash + optional wallet draw), respecting:
  # - Prefer keeping free cash at its whole-portfolio target (use wallet surplus first).
  # - If wallet is already below target, do not draw wallets down further (portfolios get new cash only).
  # - If gaps still exceed cash + surplus, allow optional slack down to half of the wallet target share.
  def portfolio_allocatable_for_portfolios(wallet_row, projected_total:, gap_total:, max_with_wallet:)
    hard_cap = [gap_total, max_with_wallet].min
    return hard_cap if wallet_row.blank?

    t = wallet_target_amount(wallet_row, projected_total)
    return [@amount, hard_cap].min if t.nil?

    w = wallet_row[:current_value].to_d
    return [@amount, hard_cap].min if w < t

    preferred_cap = @amount + (w - t)
    if gap_total <= preferred_cap
      [gap_total, hard_cap].min
    else
      hard_cap
    end
  end

  def wallet_target_amount(wallet_row, projected_total)
    whole = wallet_row[:whole_target]
    return nil if whole.blank? || whole[:mode] != :percentage || whole[:target_pct].blank?

    projected_total.to_d * whole[:target_pct].to_d / 100.to_d
  end

  def max_wallet_redistributable(wallet_row, projected_total)
    return 0.to_d unless wallet_row

    whole = wallet_row[:whole_target]
    return 0.to_d if whole.blank? || whole[:mode] != :percentage || whole[:target_pct].blank?

    min_wallet_target_pct = whole[:target_pct].to_d / 2.to_d
    min_wallet_value = projected_total.to_d * min_wallet_target_pct / 100.to_d
    current_wallet_value = wallet_row[:current_value].to_d
    [current_wallet_value - min_wallet_value, 0.to_d].max
  end

  def projected_capacity_gap_for_row(row, projected_total)
    whole = row[:whole_target]
    return 0.to_d if whole.blank?

    case whole[:mode]
    when :percentage
      tgt_pct = whole[:target_pct]
      return 0.to_d if tgt_pct.nil?

      target_amount = projected_total * tgt_pct.to_d / 100.to_d
      [target_amount - row[:current_value].to_d, 0.to_d].max
    when :static_amount
      tgt_amount = whole[:target_amount]
      return 0.to_d if tgt_amount.nil?

      [tgt_amount.to_d - row[:current_value].to_d, 0.to_d].max
    else
      0.to_d
    end
  end

  def allocate_targets(portfolio, portfolio_add)
    allocation_rows = PortfolioStatsService.category_allocation(portfolio)
    targeted_rows = allocation_rows.select { |row| row[:target_pct].present? || row[:target_amount].present? }
    targeted_total = targeted_rows.sum { |row| row[:value].to_d }
    projected_targeted_total = targeted_total + portfolio_add

    target_rows = allocation_rows
      .select { |row| row[:target_pct].present? || row[:target_amount].present? }
      .map do |row|
      target_amount = category_target_amount(row, projected_targeted_total)
      gap = [target_amount.to_d - row[:value].to_d, 0.to_d].max

      {
        category: row[:category],
        current_value: row[:value].to_d,
        target_amount: target_amount,
        target_gap: gap,
        suggested_add: 0.to_d
      }
    end
    if target_rows.empty? && portfolio_add.positive?
      target_rows << {
        category: "No category target (fallback)",
        current_value: 0.to_d,
        target_gap: 0.to_d,
        suggested_add: 0.to_d
      }
    end

    allocation = allocate_with_caps(portfolio_add, target_rows) { |row| row[:target_gap] }
    rows_with_percentages = with_value_percentages(allocation.rows, allocated_total: allocation.allocated_total)
    rows_with_deviation = with_target_post_add_deviations(rows_with_percentages)
    {
      rows: rows_with_deviation,
      allocated_total: allocation.allocated_total,
      unallocated_amount: allocation.remaining
    }
  end

  def category_target_amount(row, projected_targeted_total)
    if row[:target_amount].present?
      row[:target_amount].to_d
    elsif row[:target_pct].present?
      projected_targeted_total * row[:target_pct].to_d / 100.to_d
    end
  end

  def with_value_percentages(rows, allocated_total:)
    current_total = rows.sum { |row| row[:current_value].to_d }
    resulted_total = current_total + allocated_total.to_d

    rows.map do |row|
      current_value = row[:current_value].to_d
      suggested_add = row[:suggested_add].to_d
      resulted_value = current_value + suggested_add
      current_pct = percentage_of(current_value, current_total)
      resulted_pct = percentage_of(resulted_value, resulted_total)

      {
        **row,
        current_pct: current_pct,
        resulted_value: resulted_value,
        resulted_pct: resulted_pct
      }
    end
  end

  def allocate_with_caps(total_amount, rows)
    return AllocationResult.new(rows: rows, allocated_total: 0.to_d, remaining: total_amount.to_d) if rows.empty?

    gaps_total = rows.sum { |row| yield(row).to_d }
    allocatable_total = [total_amount.to_d, gaps_total].min

    allocated_running = 0.to_d
    allocated_rows = rows.each_with_index.map do |row, idx|
      gap = yield(row).to_d
      share =
        if gap.positive? && gaps_total.positive?
          (allocatable_total * gap) / gaps_total
        else
          0.to_d
        end

      # Keep totals exact by giving remainder to the last row with a gap.
      is_last_gap_row = idx == rows.rindex { |r| yield(r).to_d.positive? }
      amount = if is_last_gap_row
        allocatable_total - allocated_running
      else
        [share, gap].min
      end
      amount = [amount, 0.to_d].max
      allocated_running += amount

      row.merge(suggested_add: amount)
    end

    remaining = total_amount.to_d - allocatable_total
    if remaining.positive?
      distributed_rows = distribute_remaining(allocated_rows, remaining) do |row|
        yield(row)
      end
      allocated_rows = distributed_rows
      allocatable_total = total_amount.to_d
    end

    AllocationResult.new(
      rows: allocated_rows,
      allocated_total: allocatable_total,
      remaining: total_amount.to_d - allocatable_total
    )
  end

  def distribute_remaining(rows, remaining)
    positive_gap_rows = rows.select { |row| yield(row).to_d.positive? }
    base_rows = positive_gap_rows.presence || rows
    return rows if base_rows.empty?

    weighted_total = base_rows.sum { |row| distribution_weight_for(row, use_gap: positive_gap_rows.present?) }
    weighted_total = base_rows.size.to_d if weighted_total.zero?

    distributed_running = 0.to_d
    last_index = base_rows.size - 1
    suggested_by_object_id = {}

    base_rows.each_with_index do |row, idx|
      base_weight = distribution_weight_for(row, use_gap: positive_gap_rows.present?)
      base_weight = 1.to_d if base_weight.zero? && weighted_total == base_rows.size.to_d
      add =
        if idx == last_index
          remaining - distributed_running
        else
          (remaining * base_weight) / weighted_total
        end
      add = [add, 0.to_d].max
      distributed_running += add
      suggested_by_object_id[row.object_id] = row[:suggested_add].to_d + add
    end

    rows.map do |row|
      next row unless suggested_by_object_id.key?(row.object_id)

      row.merge(suggested_add: suggested_by_object_id[row.object_id])
    end
  end

  def distribution_weight_for(row, use_gap:)
    return row[:target_gap].to_d if use_gap && row.key?(:target_gap)
    return row[:capacity_gap].to_d if use_gap && row.key?(:capacity_gap)

    value = row[:current_value].to_d
    return value if value.positive?

    1.to_d
  end

  def percentage_of(value, total)
    return 0.to_d if total.to_d.zero?

    (value.to_d / total.to_d) * 100.to_d
  end

  def with_top_level_post_add_deviations(rows, allocated_total:)
    projected_total = rows.sum { |row| row[:current_value].to_d } + allocated_total.to_d

    rows.map do |row|
      target_amount = top_level_target_amount(row, projected_total)
      deviation_amount, deviation_pct = target_deviation_from_amount(
        row[:resulted_value].to_d,
        target_amount,
        overall_total: projected_total
      )
      row.merge(
        target_amount_after_add: target_amount,
        deviation_after_add_amount: deviation_amount,
        deviation_after_add_pct: deviation_pct
      )
    end
  end

  def top_level_target_amount(row, projected_total)
    whole = row[:whole_target]
    return nil if whole.blank?

    case whole[:mode]
    when :percentage
      return nil if whole[:target_pct].nil?

      projected_total * whole[:target_pct].to_d / 100.to_d
    when :static_amount
      whole[:target_amount]&.to_d
    end
  end

  def with_target_post_add_deviations(rows)
    projected_total = rows.sum { |row| row[:resulted_value].to_d }

    rows.map do |row|
      target_amount = row[:target_amount]&.to_d
      deviation_amount, deviation_pct = target_deviation_from_amount(
        row[:resulted_value].to_d,
        target_amount,
        overall_total: projected_total
      )
      row.merge(
        deviation_after_add_amount: deviation_amount,
        deviation_after_add_pct: deviation_pct
      )
    end
  end

  def target_deviation_from_amount(resulted_value, target_amount, overall_total:)
    return [nil, nil] if target_amount.nil?

    deviation_amount = resulted_value.to_d - target_amount.to_d
    deviation_pct = percentage_of(deviation_amount, overall_total)
    [deviation_amount, deviation_pct]
  end
end
