# frozen_string_literal: true

class AddUserToPortfolios < ActiveRecord::Migration[7.2]
  def up
    add_reference :portfolios, :user, null: true, foreign_key: true

    # Backfill all existing portfolios to the first user
    first_user_id = User.first&.id
    if first_user_id
      Portfolio.update_all(user_id: first_user_id)
    end

    change_column_null :portfolios, :user_id, false
  end

  def down
    remove_reference :portfolios, :user, foreign_key: true
  end
end
