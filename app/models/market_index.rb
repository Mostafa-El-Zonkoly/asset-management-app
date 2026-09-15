# frozen_string_literal: true

class MarketIndex < ApplicationRecord
  include TenantScoped

  # Base path for building a Mubasher index fetch URL from `fetch_code`.
  MUBASHER_INDEX_BASE = "https://www.mubasher.info/markets/EGX/indices"

  belongs_to :currency
  has_many :assets, dependent: :restrict_with_error
  has_many :index_prices, dependent: :destroy

  validates :name, :code, presence: true
  validates :code, uniqueness: { case_sensitive: false, scope: :user_id }
  validates :index_kind, inclusion: { in: %w[price total_return] }

  # Official market benchmarks (EGX30, EGX33 Shariah) surfaced by the Portfolio
  # Performance "Show benchmarks" toggle. Ordinary indices a fund tracks are not.
  scope :benchmarks, -> { where(is_benchmark: true).order(:code) }

  # Indices to include in the daily price-fetch sweep: active and with a handle to
  # fetch from (either a full URL override or a provider fetch_code).
  scope :fetchable, lambda {
    where(is_active: true)
      .where("NULLIF(source_identifier, '') IS NOT NULL OR NULLIF(fetch_code, '') IS NOT NULL")
  }

  # The URL the price-fetch scraper reads. Prefers an explicit full URL override
  # (source_identifier); otherwise builds .../indices/<fetch_code>/ from the code.
  def fetch_url
    explicit = source_identifier.to_s.strip
    return explicit if explicit.present?

    fc = fetch_code.to_s.strip
    return nil if fc.empty?

    "#{MUBASHER_INDEX_BASE}/#{fc}/"
  end

  def fetchable?
    is_active? && fetch_url.present?
  end

  # Published price index vs. total-return index (affects the dividend-inclusion
  # tooltip in the comparison UI, spec #15). Defaults to price when unset.
  def price_index?
    index_kind.to_s != "total_return"
  end

  def total_return_index?
    index_kind.to_s == "total_return"
  end
end
