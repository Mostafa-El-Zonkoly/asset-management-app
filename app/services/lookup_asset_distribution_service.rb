# frozen_string_literal: true

# Groups non-wallet portfolio holdings (and realised P/L on those assets) by a lookup dimension.
# All amounts are in reporting currency. Value % is each row's share of the total value shown in the table.
class LookupAssetDistributionService
  Result = Struct.new(:rows, :totals, :table_key, keyword_init: true)
  DistributionRow = Struct.new(
    :lookup_id,
    :key,
    :label,
    :asset_count,
    :total_cost,
    :total_value,
    :value_share_pct,
    :unrealised_gain,
    :unrealised_gain_pct,
    :realised_gain,
    :realised_gain_pct,
    :total_gain,
    :total_gain_pct,
    keyword_init: true
  )

  TABLE_MODEL = {
    "asset_types" => AssetType,
    "stock_purposes" => StockPurpose,
    "sectors" => Sector,
    "specialities" => Speciality,
    "fund_types" => FundType,
    "fund_styles" => FundStyle,
    "management_styles" => ManagementStyle,
    "category_types" => CategoryType
  }.freeze

  class << self
    def distributable_tables
      TABLE_MODEL.keys
    end

    def build(table_key)
      new(table_key).build
    end
  end

  def initialize(table_key)
    @table_key = table_key.to_s
    @model = TABLE_MODEL[@table_key]
    @base_id = Currency.reporting_currency_id
  end

  def build
    return Result.new(rows: [], totals: empty_totals, table_key: @table_key) if @model.blank?

    accum = Hash.new { |h, k| h[k] = { cost: 0.to_d, value: 0.to_d, unreal: 0.to_d, real: 0.to_d } }
    holding_count_per_bucket = Hash.new(0)
    # Track which asset_ids have a current non-zero holding (for transaction filtering)
    active_asset_ids = Set.new

    Holding.joins(:asset).merge(Asset.active).where.not(quantity: 0).includes(asset: asset_includes).find_each do |h|
      next if h.asset.wallet?

      bid = bucket_id(h.asset)
      next if bid == :skip

      r = HoldingsCalculatorService.for_holding(h)
      row = accum[bid]
      row[:cost] += r.cost_basis
      row[:value] += r.current_value
      row[:unreal] += r.unrealised_gain
      holding_count_per_bucket[bid] += 1
      active_asset_ids << h.asset_id
    end

    realised_and_dividends_per_bucket(accum, active_asset_ids)

    rows = []
    active_ids = []
    @model.active.order(:position, :label).each do |rec|
      lid = rec.id
      active_ids << lid
      a = accum[lid]
      next if holding_count_per_bucket[lid].zero? && a[:real].zero?

      rows << build_distribution_row(
        lookup_id: lid,
        key: rec.key,
        label: rec.label,
        asset_count: holding_count_per_bucket[lid],
        a: a
      )
    end

    (accum.keys.compact - active_ids).sort.each do |lid|
      next if holding_count_per_bucket[lid].zero?

      rec = @model.find_by(id: lid)
      a = accum[lid]
      rows << build_distribution_row(
        lookup_id: lid,
        key: rec&.key,
        label: rec&.label || "Inactive / removed (#{lid})",
        asset_count: holding_count_per_bucket[lid],
        a: a
      )
    end

    if accum.key?(nil) && holding_count_per_bucket[nil] > 0
      rows << build_distribution_row(
        lookup_id: nil,
        key: nil,
        label: "Unassigned",
        asset_count: holding_count_per_bucket[nil],
        a: accum[nil]
      )
    end

    grand_value = rows.sum { |r| r.total_value.to_d }
    rows.each do |r|
      r.value_share_pct = share_percent(r.total_value, grand_value)
      r.unrealised_gain_pct = gain_percent(r.unrealised_gain, r.total_cost)
      r.realised_gain_pct = gain_percent(r.realised_gain, r.total_cost)
      r.total_gain_pct = gain_percent(r.total_gain, r.total_cost)
    end

    Result.new(rows: rows, totals: build_totals(rows), table_key: @table_key)
  end

  private

  def asset_includes
    [ :currency, :asset_type, :stock_purpose, :sector, :speciality, :fund_type, :fund_style,
      :management_style, { category: :category_type } ]
  end

  def bucket_id(asset)
    case @table_key
    when "asset_types"
      asset.asset_type_id
    when "stock_purposes"
      asset.stock_purpose_id
    when "sectors"
      return :skip unless asset.direct_stock?

      asset.sector_id
    when "specialities"
      return :skip unless asset.direct_stock?

      asset.speciality_id
    when "fund_types"
      return :skip unless asset.mutual_fund?

      asset.fund_type_id
    when "fund_styles"
      return :skip unless asset.mutual_fund?

      asset.fund_style_id
    when "management_styles"
      return :skip unless asset.mutual_fund?

      asset.management_style_id
    when "category_types"
      asset.category&.category_type_id
    else
      nil
    end
  end

  def realised_and_dividends_per_bucket(accum, active_asset_ids)
    dividend_type = TransactionType.find_by(key: "cash_dividend")

    PortfolioTransaction.includes(:asset, :transaction_type).where.not(portfolio_id: nil).find_each do |t|
      next if t.asset.blank? || t.asset.wallet?
      next unless t.asset.active?
      next unless active_asset_ids.include?(t.asset_id)

      bid = bucket_id(t.asset)
      next if bid == :skip

      row = accum[bid]
      if t.realised_gain.present?
        row[:real] += convert(t.realised_gain, t.currency_id)
      elsif dividend_type && t.transaction_type_id == dividend_type.id
        row[:real] += convert(t.total_amount, t.currency_id)
      end
    end
  end

  def convert(amount, from_id)
    return amount.to_d if @base_id.blank?

    CurrencyConversionService.convert(amount, from_id, @base_id)
  end

  def build_distribution_row(lookup_id:, key:, label:, asset_count:, a:)
    DistributionRow.new(
      lookup_id: lookup_id,
      key: key,
      label: label,
      asset_count: asset_count,
      total_cost: a[:cost],
      total_value: a[:value],
      value_share_pct: 0.to_d,
      unrealised_gain: a[:unreal],
      unrealised_gain_pct: 0.to_d,
      realised_gain: a[:real],
      realised_gain_pct: 0.to_d,
      total_gain: a[:unreal] + a[:real],
      total_gain_pct: 0.to_d
    )
  end

  def build_totals(rows)
    cost = rows.sum { |r| r.total_cost.to_d }
    value = rows.sum { |r| r.total_value.to_d }
    unreal = rows.sum { |r| r.unrealised_gain.to_d }
    real = rows.sum { |r| r.realised_gain.to_d }
    total = unreal + real
    DistributionRow.new(
      lookup_id: nil,
      key: nil,
      label: "Total",
      asset_count: rows.sum(&:asset_count),
      total_cost: cost,
      total_value: value,
      value_share_pct: 100.to_d,
      unrealised_gain: unreal,
      unrealised_gain_pct: gain_percent(unreal, cost),
      realised_gain: real,
      realised_gain_pct: gain_percent(real, cost),
      total_gain: total,
      total_gain_pct: gain_percent(total, cost)
    )
  end

  def empty_totals
    z = 0.to_d
    DistributionRow.new(
      lookup_id: nil,
      key: nil,
      label: "Total",
      asset_count: 0,
      total_cost: z,
      total_value: z,
      value_share_pct: z,
      unrealised_gain: z,
      unrealised_gain_pct: z,
      realised_gain: z,
      realised_gain_pct: z,
      total_gain: z,
      total_gain_pct: z
    )
  end

  def share_percent(part, whole)
    return 0.to_d if whole.blank? || whole.zero?

    (part.to_d / whole) * 100
  end

  def gain_percent(gain, cost_basis)
    return ((gain / cost_basis) * 100) if cost_basis.nonzero?
    return 100.to_d if gain.positive?
    return -100.to_d if gain.negative?

    0.to_d
  end
end
