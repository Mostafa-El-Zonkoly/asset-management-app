# frozen_string_literal: true

# A single valuation / target estimate for an asset, from one source at one date.
# Estimates are never overwritten: a revised target is a new row, and only the
# newest active row per (source_family, estimate_type, horizon bucket) participates
# in current aggregates (see AssetEstimateSummaryService). static_target on Asset
# remains as a legacy fallback and is untouched by this model.
class AssetEstimate < ApplicationRecord
  include TenantScoped
  tenant_through :asset

  belongs_to :asset
  belongs_to :currency

  ESTIMATE_TYPES = %w[fundamental analyst_consensus technical internal_model other].freeze
  DATA_ROLES     = %w[data research recommendation].freeze
  HORIZON_TYPES  = %w[short_term medium_term twelve_month long_term custom].freeze

  ESTIMATE_TYPE_LABELS = {
    "fundamental" => "Fundamental",
    "analyst_consensus" => "Analyst consensus",
    "technical" => "Technical",
    "internal_model" => "Internal model",
    "other" => "Other"
  }.freeze

  DATA_ROLE_LABELS = {
    "data" => "Data only",
    "research" => "Research",
    "recommendation" => "Recommendation"
  }.freeze

  HORIZON_TYPE_LABELS = {
    "short_term" => "Short term",
    "medium_term" => "Medium term",
    "twelve_month" => "12 month",
    "long_term" => "Long term",
    "custom" => "Custom"
  }.freeze

  # Which estimate_types are grouped under each asset-page section.
  SECTION_FOR_TYPE = {
    "fundamental" => :fundamental,
    "internal_model" => :fundamental,
    "analyst_consensus" => :consensus,
    "technical" => :technical,
    "other" => :fundamental
  }.freeze

  # Freshness thresholds (days) by estimate_type: [fresh_max, aging_max].
  # Beyond aging_max => stale. Configurable via AnalyticsSetting later; these are defaults.
  FRESHNESS_THRESHOLDS = {
    "technical" => [30, 60],
    "fundamental" => [120, 240],
    "analyst_consensus" => [120, 240],
    "internal_model" => [120, 240],
    "other" => [120, 240]
  }.freeze
  DEFAULT_FRESHNESS = [120, 240].freeze

  validates :source_name, presence: true
  validates :estimate_date, presence: true
  validates :estimate_type, inclusion: { in: ESTIMATE_TYPES }
  validates :data_role, inclusion: { in: DATA_ROLES }
  validates :horizon_type, inclusion: { in: HORIZON_TYPES }
  validates :target_price, :target_min, :target_max, :confidence_score,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :confidence_score, numericality: { less_than_or_equal_to: 1 }, allow_nil: true
  # A recommendation/research row should carry a target; a data-only row need not.
  validates :target_price, presence: true, if: -> { data_role != "data" }

  scope :active, -> { where(active: true) }
  scope :recommending, -> { where.not(data_role: "data") } # rows that may contribute a target
  scope :of_type, ->(t) { where(estimate_type: t) }
  scope :chronological, -> { order(estimate_date: :desc, created_at: :desc) }

  # The independence key: explicit source_family, else the source_name itself.
  def family_key
    source_family.presence || "name:#{source_name}"
  end

  def estimate_type_label
    ESTIMATE_TYPE_LABELS[estimate_type] || estimate_type
  end

  def horizon_type_label
    HORIZON_TYPE_LABELS[horizon_type] || horizon_type
  end

  def data_role_label
    DATA_ROLE_LABELS[data_role] || data_role
  end

  def section
    SECTION_FOR_TYPE[estimate_type] || :fundamental
  end

  def age_days(as_of = Date.current)
    return nil if estimate_date.blank?

    (as_of - estimate_date.to_date).to_i
  end

  # :fresh | :aging | :stale
  def freshness(as_of = Date.current)
    days = age_days(as_of)
    return :unknown if days.nil?

    fresh_max, aging_max = FRESHNESS_THRESHOLDS[estimate_type] || DEFAULT_FRESHNESS
    return :fresh if days <= fresh_max
    return :aging if days <= aging_max

    :stale
  end

  def stale?(as_of = Date.current)
    freshness(as_of) == :stale
  end
end
