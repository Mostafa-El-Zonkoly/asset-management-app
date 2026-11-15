# frozen_string_literal: true

class CreateEfgCredentials < ActiveRecord::Migration[7.2]
  def change
    # App-wide singleton (not tenant-scoped). Trading ID + API key are stored
    # only as one encrypted blob; there is no plaintext column.
    create_table :efg_credentials do |t|
      t.text :encrypted_payload, null: false
      t.string :company_code, null: false, default: "003"
      t.string :updated_by_email
      t.datetime :last_verified_at
      t.timestamps
    end
  end
end
