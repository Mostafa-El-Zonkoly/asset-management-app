# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require_relative "fetch_error"

module Efg
  class IndexStream
    def self.fetch(trading_id:, token:, index_ids:)
      request = JSON.generate(trading_id: trading_id, token: token, index_ids: index_ids)
      # Pass secrets through stdin. Provider and SDK diagnostics can contain
      # connection details, so only forward the helper's structured response.
      Open3.popen2(ENV.fetch("EFG_STREAM_PYTHON", "python3"),
                  File.join(__dir__, "index_snapshot.py"), err: File::NULL) do |input, output, process|
        begin
          body = Timeout.timeout(30) do
            input.write(request)
            input.close
            response = output.read
            status = process.value
            raise FetchError, "EFG stream helper failed (exit #{status.exitstatus || 'signal'})" unless status.success?

            response
          end

          JSON.parse(body)
        rescue Timeout::Error
          begin
            Process.kill("KILL", process.pid) if process.alive?
          rescue Errno::ESRCH
            # The helper exited after the timeout.
          end
          raise FetchError, "EFG stream helper timed out"
        end
      end
    rescue Errno::ENOENT
      raise FetchError, "Python is unavailable for EFG streaming"
    rescue Errno::EPIPE, JSON::ParserError
      raise FetchError, "EFG stream helper returned an invalid response"
    end
  end
end
