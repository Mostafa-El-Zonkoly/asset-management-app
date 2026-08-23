# frozen_string_literal: true

class AssetType < ApplicationRecord
  include LookupRow

  has_many :assets, dependent: :restrict_with_error
end
