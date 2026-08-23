# frozen_string_literal: true

class Category < ApplicationRecord
  belongs_to :category_type
  has_many :assets, dependent: :restrict_with_error
  has_many :portfolio_targets, dependent: :destroy

  validates :name, presence: true
end
