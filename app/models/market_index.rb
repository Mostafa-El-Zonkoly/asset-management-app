# frozen_string_literal: true

class MarketIndex < ApplicationRecord
  include TenantScoped
  belongs_to :currency
  has_many :assets, dependent: :restrict_with_error
  has_many :index_prices, dependent: :destroy

  validates :name, :code, presence: true
  validates :code, uniqueness: { case_sensitive: false, scope: :user_id }
  validates :index_kind, inclusion: { in: %w[price total_return] }

  # Official market benchmarks (EGX30, EGX33 Shariah) surfaced by the Portfolio
  # Performance "Show benchmarks" toggle. Ordinary indices a fund tracks are not.
  scope :benchmarks, -> { where(is_benchmark: true).order(:code) }

  # Indices to include in the daily price-fetch sweep: active and with a provider
  # handle to fetch from.
  scope :fetchable, -> { where(is_active: true).where.not(source_identifier: [nil, ""]) }

  # Published price index vs. total-return index (affects the dividend-inclusion
  # tooltip in the comparison UI, spec #15). Defaults to price when unset.
  def price_index?
    index_kind.to_s != "total_return"
  end

  def total_return_index?
    index_kind.to_s == "total_return"
  end
end
