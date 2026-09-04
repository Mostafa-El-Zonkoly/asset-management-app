class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :portfolios, dependent: :destroy

  # Give every new account the reference framework it needs to be usable.
  after_commit :provision_reference_data, on: :create

  def admin?
    !!admin
  end

  private

  def provision_reference_data
    ReferenceDataSeeder.seed_for(self)
  rescue => e
    Rails.logger.error("[provision] user=#{id} failed: #{e.class}: #{e.message}")
  end
end
