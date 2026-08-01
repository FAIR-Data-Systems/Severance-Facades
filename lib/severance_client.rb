# frozen_string_literal: true

require 'net/http'
require 'json'
require 'csv'
require 'uri'

# Owns the submit -> poll -> fetch cycle against Severance External for a
# single incoming Beacon request. Blocking by design: the facade holds the
# HTTP connection to the Beacon caller open for the whole cycle so ERDERA
# never sees Severance's async job mechanics (see handoff-beacon-caresm.md).
class SeveranceClient
  class PollTimeout < StandardError; end
  class QueryFailed < StandardError; end

  def initialize(base_url:, auth_token:, poll_interval: 1.0, poll_ceiling: 20.0)
    @base_url = base_url
    @auth_token = auth_token
    @poll_interval = poll_interval
    @poll_ceiling = poll_ceiling
  end

  # @param query_id [String] "individuals_exists" or "individuals_count"
  # @param bindings [Hash] Severance binding hash (only bound filters included)
  # @return [Array<Hash>] result rows, each a String-keyed Hash of column => value
  def query(query_id:, bindings:)
    location = submit(query_id, bindings)
    poll(location)
  end

  private

  def submit(query_id, bindings)
    uri = URI("#{@base_url}/severance/queries")
    req = Net::HTTP::Post.new(uri)
    req['Content-Type'] = 'application/json'
    req['Authorization'] = "Bearer #{@auth_token}"
    req.body = JSON.generate({ query_id: query_id, bindings: bindings })

    res = http_request(uri, req)
    raise QueryFailed, "Severance rejected query submission: #{res.code} #{res.body}" unless res.code.to_i == 201

    location = res['Location']
    raise QueryFailed, 'Severance did not return a Location header' unless location

    location
  end

  def poll(location)
    uri = URI(location)
    deadline = Time.now + @poll_ceiling

    loop do
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{@auth_token}"
      req['Accept'] = 'application/json'

      res = http_request(uri, req)

      return parse_result(res) if res.code.to_i == 200
      unless [201, 202].include?(res.code.to_i)
        raise QueryFailed, "Severance job failed: #{res.code} #{res.body}"
      end

      raise PollTimeout, "Poll ceiling (#{@poll_ceiling}s) reached for #{location}" if Time.now > deadline

      sleep @poll_interval
    end
  end

  def http_request(uri, req)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
  end

  def parse_result(res)
    content_type = res['Content-Type'].to_s

    if content_type.include?('csv')
      CSV.parse(res.body.to_s, headers: true).map(&:to_h)
    else
      json = JSON.parse(res.body.to_s)
      bindings = json.dig('results', 'bindings') || []
      bindings.map { |row| row.transform_values { |v| v['value'] } }
    end
  end
end
