# frozen_string_literal: true

require "test_helper"

class TransactionPortfolioUpdateServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  test "moves buy holding between portfolios" do
    p1 = Portfolio.find_by!(name: "Main")
    p2 = Portfolio.create!(name: "Side portfolio")
    stock = Asset.find_by!(code: "COMI")
    buy = PortfolioTransaction.find_by!(
      portfolio: p1,
      asset: stock,
      transaction_type: TransactionType.find_by!(key: "buy")
    )

    TransactionPortfolioUpdateService.call!(buy, portfolio_id: p2.id)

    h1 = Holding.find_by(portfolio: p1, asset: stock)
    h2 = Holding.find_by!(portfolio: p2, asset: stock)

    assert_equal 0.to_d, h1&.quantity.to_d
    assert_equal 100.to_d, h2.quantity.to_d
    assert_equal p2.id, buy.reload.portfolio_id
  end

  test "updates cash dividend portfolio without changing holdings" do
    p1 = Portfolio.find_by!(name: "Main")
    p2 = Portfolio.create!(name: "Income portfolio")
    wallet = Asset.find_by!(code: "CASH_EGP")
    stock = Asset.find_by!(code: "COMI")
    cd_type = TransactionType.find_by!(key: "cash_dividend")

    tx = PortfolioTransaction.create!(
      portfolio: p1,
      asset: stock,
      transaction_type: cd_type,
      quantity: 1,
      total_amount: 120,
      currency_id: stock.currency_id,
      date: Time.current,
      related_wallet_id: wallet.id
    )

    TransactionPortfolioUpdateService.call!(tx, portfolio_id: p2.id)

    assert_equal p2.id, tx.reload.portfolio_id
  end

  test "rejects wallet-only transaction" do
    wallet = Asset.find_by!(code: "CASH_EGP")
    dep = PortfolioTransaction.find_by!(asset: wallet, transaction_type: TransactionType.find_by!(key: "deposit"))

    assert_raises(TransactionPortfolioUpdateService::Error) do
      TransactionPortfolioUpdateService.call!(dep, portfolio_id: Portfolio.find_by!(name: "Main").id)
    end
  end
end
