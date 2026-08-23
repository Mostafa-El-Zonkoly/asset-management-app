# frozen_string_literal: true

class TransactionType < ApplicationRecord
  include LookupRow

  has_many :portfolio_transactions, dependent: :restrict_with_error
end
