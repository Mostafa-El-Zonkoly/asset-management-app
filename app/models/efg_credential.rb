# frozen_string_literal: true

require Rails.root.join("lib/efg/client")

# App-wide EFG Hermes API credentials (Trading ID + API key), used to fetch EGX
# stock prices. WRITE-ONLY from the UI: they can be set, replaced, tested or
# cleared, but no controller or view ever renders them. They're stored as one
# AES-256-GCM blob keyed from SECRET_KEY_BASE (rotating SECRET_KEY_BASE means
# re-entering them). Only OWNER_EMAIL may manage them.
class EfgCredential < ApplicationRecord
  OWNER_EMAIL = "m.zonkoly@gmail.com"
  COMPANY_CODES = Efg::Client::COMPANY_CODES
  KEY_SALT = "efg-credentials/v1"

  self.filter_attributes += [:encrypted_payload]

  validates :encrypted_payload, presence: true
  validates :company_code, inclusion: { in: COMPANY_CODES }

  class << self
    def manageable_by?(user)
      user.present? && user.email.to_s.strip.casecmp?(OWNER_EMAIL)
    end

    def current
      order(:id).first
    end

    def configured?
      current.present?
    end

    # Replace the stored credentials. Both secrets are required every time.
    def store!(trading_id:, api_key:, company_code:, by:)
      raise ArgumentError, "not allowed" unless manageable_by?(by)

      trading_id = trading_id.to_s.strip
      api_key = api_key.to_s.strip
      if trading_id.empty? || api_key.empty?
        raise ActiveRecord::RecordInvalid.new(new.tap { |r| r.errors.add(:base, "Trading ID and API key are both required") })
      end
      if [trading_id, api_key].any? { |v| v.length > 4096 || v.match?(/[[:cntrl:]]/) }
        raise ActiveRecord::RecordInvalid.new(new.tap { |r| r.errors.add(:base, "Invalid credential format") })
      end

      transaction do
        record = current || new
        record.encrypted_payload = encryptor.encrypt_and_sign(JSON.generate("trading_id" => trading_id, "api_key" => api_key))
        record.company_code = company_code.to_s.strip.presence || "003"
        record.updated_by_email = by.email
        record.last_verified_at = nil
        record.save!
        where.not(id: record.id).delete_all
        record
      end
      Efg::Client.clear_cache!
    end

    def clear!(by:)
      raise ArgumentError, "not allowed" unless manageable_by?(by)

      delete_all
      Efg::Client.clear_cache!
    end

    # Server-side only: a client built from the stored credentials, or nil.
    def client
      current&.send(:build_client)
    end

    def encryptor
      key = Rails.application.key_generator.generate_key(KEY_SALT, ActiveSupport::MessageEncryptor.key_len)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
  end

  def inspect
    "#<EfgCredential id: #{id.inspect}, company_code: #{company_code.inspect}, updated_at: #{updated_at.inspect}>"
  end

  private

  def build_client
    secrets = JSON.parse(self.class.encryptor.decrypt_and_verify(encrypted_payload))
    Efg::Client.new(trading_id: secrets["trading_id"], api_key: secrets["api_key"], company_code: company_code)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature, JSON::ParserError
    raise Efg::FetchError, "Stored EFG credentials can't be decrypted (was SECRET_KEY_BASE changed?). Please set them again."
  end
end
