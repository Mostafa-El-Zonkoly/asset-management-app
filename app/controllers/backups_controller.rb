require "open3"

class BackupsController < ApplicationController
  before_action :require_admin
  # Common pg binary locations on macOS (Homebrew, Postgres.app, libpq)
  PG_BIN_DIRS = %w[
    /usr/local/Cellar/libpq/18.4/bin
    /opt/homebrew/bin
    /usr/local/bin
    /opt/homebrew/opt/postgresql@17/bin
    /opt/homebrew/opt/postgresql@16/bin
    /opt/homebrew/opt/postgresql@15/bin
    /Applications/Postgres.app/Contents/Versions/latest/bin
  ].freeze

  # GET /backup/export  — download a .dump of the current DB
  def export
    filename = "portfolio_app_#{Time.current.strftime('%Y%m%d_%H%M%S')}.dump"
    data = run_pg_dump
    send_data data, filename: filename, type: "application/octet-stream", disposition: "attachment"
  rescue => e
    redirect_back fallback_location: root_path, alert: "❌ Export failed: #{e.message.last(300)}"
  end

  # GET /backup/import  — upload form
  def import
  end

  # POST /backup/restore  — restore from an uploaded .dump file
  def restore
    file = params[:dump_file]
    return redirect_back(fallback_location: root_path, alert: "❌ No file selected.") unless file

    run_pg_restore(file.path)
    redirect_back fallback_location: root_path, notice: "✅ Database restored successfully."
  rescue => e
    redirect_back fallback_location: root_path, alert: "❌ Restore failed: #{e.message.last(300)}"
  end

  private

  def require_admin
    return if current_user&.admin?

    redirect_to root_path, alert: "Not authorized."
  end

  def db_cfg
    ActiveRecord::Base.connection_db_config.configuration_hash
  end

  def pg_bin(name)
    # Try explicit dirs first, then fall back to whatever is on PATH
    PG_BIN_DIRS.map { |d| File.join(d, name) }.find { |p| File.executable?(p) } || name
  end

  def pg_env
    { "PGPASSWORD" => db_cfg[:password].to_s }
  end

  def pg_conn_args
    [
      "-h", db_cfg[:host] || "localhost",
      "-p", (db_cfg[:port] || 5432).to_s,
      "-U", db_cfg[:username] || "postgres"
    ]
  end

  def run_pg_dump
    cmd = [pg_bin("pg_dump"), *pg_conn_args, "-Fc", db_cfg[:database]]
    out, err, status = Open3.capture3(pg_env, *cmd)
    raise err.presence || "pg_dump failed (exit #{status.exitstatus})" unless status.success?
    out
  end

  def run_pg_restore(filepath)
    cmd = [
      pg_bin("pg_restore"),
      *pg_conn_args,
      "--clean", "--if-exists", "--no-owner", "--no-acl",
      "-d", db_cfg[:database],
      filepath
    ]
    out, status = Open3.capture2e(pg_env, *cmd)
    raise out unless status.success?
  end
end
