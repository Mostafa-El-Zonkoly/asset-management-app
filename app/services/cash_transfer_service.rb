# frozen_string_literal: true

require "bigdecimal"

# Creates external cash movements as PortfolioCashFlow records, auto-classifying by
# endpoints and generating BOTH legs of a portfolio-to-portfolio transfer (spec T).
#   Wallet    -> Portfolio : contribution
#   Portfolio -> Wallet    : withdrawal
#   Portfolio -> Portfolio : transfer_out (source) + transfer_in (dest), linked
class CashTransferService
  class Error < StandardError; end

  class << self
    def call(**kwargs)
      new.call(**kwargs)
    end
  end

  # from/to: { type: "wallet"|"portfolio", id: }. amount > 0.
  def call(from:, to:, amount:, currency_id:, occurred_at: Time.current, notes: nil)
    amt = amount.to_d
    raise Error, "Amount must be positive" if amt <= 0
    raise Error, "A cash move needs different endpoints" if from == to

    case [from[:type].to_s, to[:type].to_s]
    when %w[wallet portfolio]
      contribute!(portfolio_id: to[:id], wallet_id: from[:id], amount: amt, currency_id: currency_id, occurred_at: occurred_at, notes: notes)
    when %w[portfolio wallet]
      withdraw!(portfolio_id: from[:id], wallet_id: to[:id], amount: amt, currency_id: currency_id, occurred_at: occurred_at, notes: notes)
    when %w[portfolio portfolio]
      transfer!(source_id: from[:id], dest_id: to[:id], amount: amt, currency_id: currency_id, occurred_at: occurred_at, notes: notes)
    else
      raise Error, "Wallet-to-wallet moves use the existing Transfer between wallets."
    end
  end

  def contribute!(portfolio_id:, wallet_id:, amount:, currency_id:, occurred_at: Time.current, notes: nil)
    portfolio = Portfolio.find(portfolio_id)
    wallet = Asset.find(wallet_id)
    raise Error, "Source must be a wallet" unless wallet.wallet?

    PortfolioCashFlow.create!(
      portfolio: portfolio, currency_id: currency_id, related_wallet_id: wallet.id,
      kind: "contribution", amount: amount, occurred_at: occurred_at, notes: notes
    )
  end

  def withdraw!(portfolio_id:, wallet_id:, amount:, currency_id:, occurred_at: Time.current, notes: nil)
    portfolio = Portfolio.find(portfolio_id)
    wallet = Asset.find(wallet_id)
    raise Error, "Destination must be a wallet" unless wallet.wallet?

    PortfolioCashFlow.create!(
      portfolio: portfolio, currency_id: currency_id, related_wallet_id: wallet.id,
      kind: "withdrawal", amount: amount, occurred_at: occurred_at, notes: notes
    )
  end

  def transfer!(source_id:, dest_id:, amount:, currency_id:, occurred_at: Time.current, notes: nil)
    raise Error, "Transfer needs two different portfolios" if source_id.to_i == dest_id.to_i

    source = Portfolio.find(source_id)
    dest = Portfolio.find(dest_id)
    pair = SecureRandom.uuid

    ActiveRecord::Base.transaction do
      PortfolioCashFlow.create!(
        portfolio: source, currency_id: currency_id, counterparty_portfolio_id: dest.id,
        kind: "transfer_out", amount: amount, occurred_at: occurred_at, transfer_pair_id: pair, notes: notes
      )
      PortfolioCashFlow.create!(
        portfolio: dest, currency_id: currency_id, counterparty_portfolio_id: source.id,
        kind: "transfer_in", amount: amount, occurred_at: occurred_at, transfer_pair_id: pair, notes: notes
      )
    end
  end
end
