# frozen_string_literal: true

class EfgBenchmarkPriceFetcher
  def initialize(run_id:, date:)
    @run_id = run_id
    @date = date
  end

  def call
    indices = MarketIndex.benchmarks.where(is_active: true).to_a
    index_ids = indices.to_h { |index| [index.id, provider_id(index)] }
    log(:info, "started", date: @date, total: indices.size, user_id: Current.user.id)

    ids = index_ids.values.compact.uniq
    snapshots, stream_error = load_snapshots(ids) if ids.any?
    updated = indices.count do |index|
      save_snapshot(index, index_ids.fetch(index.id), snapshots, stream_error)
    end
    failed = indices.size - updated
    log(:info, "finished", updated: updated, failed: failed)
    { updated: updated, failed: failed, total: indices.size }
  end

  private

  def provider_id(index)
    index.efg_index_id || (1 if index.code.to_s.strip.casecmp?("EGX30"))
  end

  def load_snapshots(ids)
    client = EfgCredential.client
    raise Efg::FetchError, "EFG credentials are missing" unless client

    log(:info, "authenticating")
    client.authenticate!
    log(:info, "subscribing", efg_index_ids: ids)
    snapshots = client.index_snapshots(ids)
    raise Efg::FetchError, snapshots["error"] if snapshots["error"]

    market = snapshots.fetch("mk1")
    raise Efg::FetchError, market["error"] if market["error"]

    status = market["m_MarketStatus"]
    time = market["MarketTime"]
    date = market_date(time)
    log(:info, "market_snapshot", market_status: status, market_time: time, market_date: date)
    unless %w[3 Closed].include?(status) && date == @date && !date.friday? && !date.saturday?
      raise Efg::FetchError, "EFG did not report a closed EGX session for #{@date}"
    end

    [snapshots, nil]
  rescue Efg::Client::AuthenticationError => e
    log(:warn, "authentication_failed", reason: e.message)
    [nil, e.message]
  rescue Efg::FetchError => e
    log(:warn, "stream_failed", reason: e.message)
    [nil, e.message]
  end

  def market_date(value)
    case value.to_s
    when /\A\d{4}-\d{2}-\d{2}(?:[ T]|\z)/
      Date.strptime(value, "%Y-%m-%d")
    when %r{\A\d{1,2}/\d{1,2}/\d{4}(?:\s|\z)}
      Date.strptime(value, "%m/%d/%Y")
    end
  rescue Date::Error
    nil
  end

  def save_snapshot(index, id, snapshots, stream_error)
    fields = { code: index.code, market_index_id: index.id, efg_index_id: id, date: @date }
    raise Efg::FetchError, "Set the EFG Hermes index ID in Market Index settings" unless id
    raise Efg::FetchError, stream_error if stream_error

    snapshot = snapshots.fetch("ix#{id}")
    raise Efg::FetchError, snapshot["error"] if snapshot["error"]

    level = Float(snapshot["m_IndexValue"], exception: false)
    unless snapshot["m_IndexID"].to_i == id && level&.finite? && level.positive? && level <= Efg::Client::MAX_PRICE
      raise Efg::FetchError, "EFG returned an invalid index ID or level"
    end

    source = efg_price_source
    IndexPrice.upsert(
      { market_index_id: index.id, user_id: index.user_id, date: @date, price: level, price_source_id: source.id },
      unique_by: %i[market_index_id date], update_only: %i[price price_source_id]
    )
    log(:info, "index_saved", **fields, provider_name: snapshot["m_EnglishName"], level: level)
    true
  rescue Efg::FetchError => e
    log(:warn, "index_failed", **fields, reason: e.message)
    false
  rescue StandardError => e
    log(:error, "index_failed", **fields, error_class: e.class.name)
    false
  end

  def efg_price_source
    @efg_price_source ||= PriceSource.find_by(key: "efg_api") || begin
      PriceSource.insert_all(
        [{ key: "efg_api", label: "EFG Hermes API", position: PriceSource.maximum(:position).to_i + 1, active: true }],
        unique_by: :key
      )
      PriceSource.find_by!(key: "efg_api")
    end
  end

  def log(severity, event, **fields)
    Rails.logger.public_send(severity, { provider: "efg_api", job: "efg_benchmark_fetch", run_id: @run_id, event: event, **fields }.to_json)
  end
end
