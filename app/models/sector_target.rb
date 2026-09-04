# frozen_string_literal: true

class SectorTarget < ApplicationRecord
  include TenantScoped
  tenant_through :sector
  belongs_to :sector

  validates :target_percentage, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :sector_id, uniqueness: true
end
