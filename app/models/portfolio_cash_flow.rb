# frozen_string_literal: true

# A single external cash movement for one portfolio. Contributions/withdrawals
# move cash between a wallet and a portfolio; transfer_in/transfer_out are the two
# legs of a portfolio-to-portfolio transfer (linked by transfer_pair_id). These are
# the only records that change a portfolio's cumulative external capital.
class PortfolioCashFlow < ApplicationRecord
  include TenantScoped
  tenant_through :portfolio

  belongs_to :portfolio
  belongs_to :currency
  belongs_to :related_wallet, class_name: "Asset", optional: true
  belongs_to :counterparty_portfolio, class_name: "Portfolio", optional: true

  KINDS = %w[contribution withdrawal transfer_in transfer_out].freeze
  KIND_LABELS = {
    "contribution" => "Contribution",
    "withdrawal" => "Withdrawal",
    "transfer_in" => "Transfer in",
    "transfer_out" => "Transfer out"
  }.freeze

  # Signed effect on the portfolio's cash balance.
  CASH_SIGN = { "contribution" => 1, "withdrawal" => -1, "transfer_in" => 1, "transfer_out" => -1 }.freeze
  # Which kinds add to cumulative external contributions vs withdrawals.
  CONTRIBUTION_KINDS = %w[contribution transfer_in].freeze
  WITHDRAWAL_KINDS   = %w[withdrawal transfer_out].freeze
  # A portfolio-to-portfolio move: external per-portfolio, internal at Master level.
  TRANSFER_KINDS     = %w[transfer_in transfer_out].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :amount, numericality: { greater_than: 0 }
  validates :occurred_at, presence: true

  scope :contributions, -> { where(kind: CONTRIBUTION_KINDS) }
  scope :withdrawals,   -> { where(kind: WITHDRAWAL_KINDS) }
  scope :transfers,     -> { where(kind: TRANSFER_KINDS) }
  scope :chronological, -> { order(:occurred_at, :id) }

  def kind_label
    KIND_LABELS[kind] || kind
  end

  def cash_sign
    CASH_SIGN[kind] || 0
  end

  def signed_cash
    amount.to_d * cash_sign
  end

  def contribution?
    CONTRIBUTION_KINDS.include?(kind)
  end

  def withdrawal?
    WITHDRAWAL_KINDS.include?(kind)
  end

  def transfer?
    TRANSFER_KINDS.include?(kind)
  end
end
