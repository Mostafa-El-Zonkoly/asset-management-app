# frozen_string_literal: true

# Give every existing account (e.g. the empty second user) the reference
# framework, now that per-user uniqueness is in place. Idempotent and guarded so
# a single failure can't abort the deploy. The data owner already has data, so
# ReferenceDataSeeder skips them.
class ProvisionExistingUsers < ActiveRecord::Migration[7.2]
  def up
    User.reset_column_information
    User.find_each do |user|
      ReferenceDataSeeder.seed_for(user)
    rescue => e
      say "provision failed for user #{user.id}: #{e.class}: #{e.message}"
    end
  end

  def down
    # no-op: leaves provisioned reference data in place
  end
end
