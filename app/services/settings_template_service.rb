# frozen_string_literal: true

# Clears a user's per-user reference settings (taxonomy + classification lookups)
# and clones them from the FIRST user account, which acts as the master template.
# Global enums (asset_types, transaction_types, etc.) are shared and untouched.
#
# Refuses when the target user still owns assets, because assets reference these
# lookups and clearing them would break those references — clone into a fresh
# (asset-free) account only.
module SettingsTemplateService
  class Error < StandardError; end

  # Per-user lookups cloned, in a FK-safe order (children before parents).
  module_function

  def clone_from_first_user!(target)
    template = User.order(:id).first
    raise Error, "No template account is available." if template.nil?
    raise Error, "This is the first (template) account, so there is nothing to clone from." if template.id == target.id
    if Asset.unscoped.where(user_id: target.id).exists?
      raise Error, "You still have assets that use these settings. Remove your assets first, then clone the template."
    end

    ActiveRecord::Base.transaction do
      clear_target!(target)
      with_tenant(target) do
        sector_map = clone_sectors(template)
        clone_specialities(template, sector_map)
        clone_simple(StockPurpose, template)
        clone_simple(FundStyle, template)
        clone_simple(ManagementStyle, template)
        clone_categories(template)
        clone_market_indices(template)
      end
    end
    true
  end

  def clear_target!(target)
    Speciality.unscoped.where(user_id: target.id).delete_all
    Sector.unscoped.where(user_id: target.id).delete_all
    StockPurpose.unscoped.where(user_id: target.id).delete_all
    FundStyle.unscoped.where(user_id: target.id).delete_all
    ManagementStyle.unscoped.where(user_id: target.id).delete_all
    idx_ids = MarketIndex.unscoped.where(user_id: target.id).pluck(:id)
    IndexPrice.unscoped.where(market_index_id: idx_ids).delete_all if idx_ids.any?
    MarketIndex.unscoped.where(user_id: target.id).delete_all
    Category.unscoped.where(user_id: target.id).delete_all
  end

  def clone_sectors(template)
    map = {}
    Sector.unscoped.where(user_id: template.id).order(:position, :id).each do |s|
      rec = Sector.create!(key: s.key, label: s.label, position: s.position, active: s.active)
      map[s.id] = rec.id
    end
    map
  end

  def clone_specialities(template, sector_map)
    Speciality.unscoped.where(user_id: template.id).order(:position, :id).each do |sp|
      new_sector_id = sector_map[sp.sector_id]
      next if new_sector_id.nil?

      Speciality.create!(key: sp.key, label: sp.label, position: sp.position, active: sp.active, sector_id: new_sector_id)
    end
  end

  def clone_simple(model, template)
    model.unscoped.where(user_id: template.id).order(:position, :id).each do |r|
      model.create!(key: r.key, label: r.label, position: r.position, active: r.active)
    end
  end

  def clone_categories(template)
    Category.unscoped.where(user_id: template.id).order(:id).each do |c|
      Category.create!(name: c.name, category_type_id: c.category_type_id, description: c.description)
    end
  end

  def clone_market_indices(template)
    tmpl_ccy = Currency.unscoped.where(user_id: template.id).index_by(&:id)
    MarketIndex.unscoped.where(user_id: template.id).order(:id).each do |mi|
      code = tmpl_ccy[mi.currency_id]&.code
      target_ccy = code && Currency.find_by(code: code)
      next if target_ccy.nil?

      MarketIndex.create!(name: mi.name, code: mi.code, description: mi.description, currency_id: target_ccy.id)
    end
  end

  def with_tenant(user)
    previous = Current.user
    Current.user = user
    yield
  ensure
    Current.user = previous
  end
end
