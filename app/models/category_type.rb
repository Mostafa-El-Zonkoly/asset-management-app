# frozen_string_literal: true

class CategoryType < ApplicationRecord
  include LookupRow

  has_many :categories, dependent: :restrict_with_error
end
