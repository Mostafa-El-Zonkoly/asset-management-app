# frozen_string_literal: true

require "test_helper"

class TransactionAmendServiceTest < ActiveSupport::TestCase
  setup { Rails.application.load_seed }

  def permit(attrs)
    ActionController::Parameters.new(attrs).permit(*TransactionAmendService::PERMITTED.map(&:to_sym))
  end

  def second_wallet
    main = Asset.find_by!(code: "CASH_EGP")
    Asset.find_or_create_by!(code: "TEST_WALLET_2") do |a|
      a.name = "Second test wallet"
      a.category_id = main.category_id
      a.asset_type_id = main.asset_type_id
      a.currency_id = main.currency_id
      a.active = true
    end
  end

  test "reduces buy quantity and holding in step" do
    portfolio = Portfolio.find_by!(name: "Main")
    stock = Asset.find_by!(code: "COMI")
    buy_type = TransactionType.find_by!(key: "buy")
    buy = PortfolioTransaction.find_by!(portfolio:, asset: stock, transaction_type: buy_type)

    TransactionAmendService.call!(
      buy,
      permit(
        portfolio_id: portfolio.id,
        quantity: "50",
        price_per_unit: "80",
        total_amount: "4000",
        currency_id: buy.currency_id,
        related_wallet_id: buy.related_wallet_id,
        date: buy.date.iso8601
      )
    )

    buy.reload
    holding = Holding.find_by!(portfolio:, asset: stock)

    assert_equal 50.to_d, buy.quantity.to_d
    assert_equal 50.to_d, holding.quantity.to_d
  end

  test "notes-only patch does not change holdings" do
    portfolio = Portfolio.find_by!(name: "Main")
    stock = Asset.find_by!(code: "COMI")
    buy_type = TransactionType.find_by!(key: "buy")
    buy = PortfolioTransaction.find_by!(portfolio:, asset: stock, transaction_type: buy_type)
    holding = Holding.find_by!(portfolio:, asset: stock)
    qty_before = holding.quantity.to_d

    TransactionAmendService.call!(buy, permit(notes: "Marked from test"))

    assert_equal qty_before, holding.reload.quantity.to_d
    assert_equal "Marked from test", buy.reload.notes
  end

  test "transfer allows notes only" do
    wallet_a = Asset.find_by!(code: "CASH_EGP")
    wallet_b = second_wallet

    transfer_type = TransactionType.find_by!(key: "transfer")
    pair = SecureRandom.uuid
    t1 = PortfolioTransaction.create!(
      portfolio_id: nil,
      asset_id: wallet_a.id,
      transaction_type: transfer_type,
      quantity: 1,
      total_amount: 10,
      currency_id: wallet_a.currency_id,
      date: Time.current,
      transfer_to_wallet_id: wallet_b.id,
      transfer_pair_id: pair
    )
    PortfolioTransaction.create!(
      portfolio_id: nil,
      asset_id: wallet_b.id,
      transaction_type: transfer_type,
      quantity: 1,
      total_amount: 10,
      currency_id: wallet_b.currency_id,
      date: Time.current,
      related_wallet_id: wallet_a.id,
      transfer_pair_id: pair
    )

    TransactionAmendService.call!(t1, permit(notes: "leg note", date: t1.date.iso8601))

    assert_equal "leg note", t1.reload.notes
  end

  test "rejects financial edit on transfer" do
    wallet_a = Asset.find_by!(code: "CASH_EGP")
    wallet_b = second_wallet

    transfer_type = TransactionType.find_by!(key: "transfer")
    pair = SecureRandom.uuid
    t1 = PortfolioTransaction.create!(
      portfolio_id: nil,
      asset_id: wallet_a.id,
      transaction_type: transfer_type,
      quantity: 1,
      total_amount: 10,
      currency_id: wallet_a.currency_id,
      date: Time.current,
      transfer_to_wallet_id: wallet_b.id,
      transfer_pair_id: pair
    )

    assert_raises(TransactionAmendService::Error) do
      TransactionAmendService.call!(
        t1,
        permit(quantity: "2", notes: "", date: t1.date.iso8601)
      )
    end
  end
end
