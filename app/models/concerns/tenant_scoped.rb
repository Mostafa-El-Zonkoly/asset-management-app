# frozen_string_literal: true

# Scopes a model to the current user (Current.user):
#   * default_scope filters every read to the current user's rows;
#   * new records are auto-assigned to the current user on create;
#   * when Current.user is nil (rake tasks, jobs, console), ownership is derived
#     from a declared parent association via `tenant_through`, so maintenance
#     code (price fetch, ledger rebuild) never creates orphaned rows.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :user, optional: true unless reflect_on_association(:user)
    default_scope { Current.user ? where(arel_table[:user_id].eq(Current.user.id)) : all }
    before_validation :assign_tenant, on: :create
  end

  class_methods do
    # Declare parent association(s) to inherit user_id from when Current.user is
    # unavailable. Tried in order; the first present parent's user wins.
    def tenant_through(*assocs)
      @tenant_through = assocs
    end

    def tenant_through_assocs
      @tenant_through || []
    end
  end

  private

  def assign_tenant
    self.user_id ||= Current.user&.id
    return if user_id.present?

    self.class.tenant_through_assocs.each do |assoc|
      parent = public_send(assoc)
      if parent.respond_to?(:user_id) && parent.user_id
        self.user_id = parent.user_id
        break
      end
    end
  end
end
