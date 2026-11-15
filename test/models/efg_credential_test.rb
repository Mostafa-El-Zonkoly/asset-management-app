# frozen_string_literal: true

require "test_helper"

class EfgCredentialTest < ActiveSupport::TestCase
  def owner = User.new(email: "M.Zonkoly@gmail.com")
  def other = users(:one)

  test "only the owner email may manage credentials" do
    assert EfgCredential.manageable_by?(owner)
    refute EfgCredential.manageable_by?(other)
    refute EfgCredential.manageable_by?(nil)
    assert_raises(ArgumentError) { EfgCredential.store!(trading_id: "a", api_key: "b", company_code: "003", by: other) }
  end

  test "stores secrets encrypted and builds a client from them" do
    EfgCredential.store!(trading_id: "TID-1", api_key: "KEY-SECRET", company_code: "009", by: owner)
    record = EfgCredential.current
    assert_equal 1, EfgCredential.count
    refute_includes record.encrypted_payload, "KEY-SECRET"
    refute_includes record.encrypted_payload, "TID-1"
    refute_includes record.inspect, record.encrypted_payload
    assert_equal "009", record.company_code
    assert_instance_of Efg::Client, EfgCredential.client
  end

  test "replacing keeps a single row; clearing removes it" do
    EfgCredential.store!(trading_id: "a", api_key: "b", company_code: "003", by: owner)
    EfgCredential.store!(trading_id: "c", api_key: "d", company_code: "003", by: owner)
    assert_equal 1, EfgCredential.count
    EfgCredential.clear!(by: owner)
    refute EfgCredential.configured?
    assert_nil EfgCredential.client
  end

  test "blank secrets are rejected" do
    assert_raises(ActiveRecord::RecordInvalid) do
      EfgCredential.store!(trading_id: "", api_key: "b", company_code: "003", by: owner)
    end
  end
end
