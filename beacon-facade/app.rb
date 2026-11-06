# frozen_string_literal: true

require 'sinatra'
require 'json'
require 'digest'
require_relative 'lib/filter_mapper'
require_relative 'lib/severance_client'
require_relative 'lib/beacon_response'

# BEACON_-prefixed env var names throughout this file are deliberate, not
# decorative -- this runs alongside Severance and other host services, and
# generic names like PORT/BIND risk colliding with unrelated env vars set
# elsewhere on the same host or in the same docker-compose file.
set :bind, ENV.fetch('BEACON_BIND', '0.0.0.0')
set :port, ENV.fetch('BEACON_PORT', '4567').to_i
# Let our `error` blocks handle exceptions even in development mode, instead
# of Sinatra's default HTML exception-trace page.
set :show_exceptions, :after_handler
# Rack::MethodOverride (on by default for classic-style apps) reads the POST
# body looking for a `_method` field -- it parses form/multipart bodies before
# RefuseMultipart below, or any route, sees the request. Nothing uses `_method`.
set :method_override, false

# Refuses multipart/form-data before anything parses it. Sinatra merges
# `request.params` (which includes a parsed multipart body) before any route or
# `before` filter runs, so every Rack multipart-parser bug was reachable by any
# caller -- e.g. GHSA-5v64-555j-wjxm (rack < 3.2.8), which holds a crafted body
# in memory in full. Beacon requests are JSON, so the parser is taken off the
# reachable surface entirely. Same guard as Severance's external/outie.rb.
class RefuseMultipart
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['CONTENT_TYPE'].to_s.downcase.include?('multipart/')
      return [415, { 'content-type' => 'application/json' }, ['{"error":"multipart bodies are not accepted"}']]
    end

    @app.call(env)
  end
end
use RefuseMultipart

# Read once at boot from the same VERSION file the Dockerfile bakes in as an
# OCI label -- so the running facade's own version is queryable via GET
# /info, not just visible on the image metadata. Distinct from
# BeaconResponse::API_VERSION, which is the Beacon API shape being emulated,
# not this codebase's own version.
FACADE_VERSION = File.read(File.join(__dir__, 'VERSION')).strip

SEVERANCE_URL = ENV.fetch('BEACON_SEVERANCE_URL', 'http://localhost:3000')
# Required. Used to fall back to 'YesItsMe', the example token Severance's own
# docs once shipped -- Severance External now refuses to start with that (or any
# token under 32 characters), so the fallback could only ever produce a facade
# that answers every query with Severance's 401. Fail at startup instead.
SEVERANCE_AUTH_TOKEN = ENV['BEACON_SEVERANCE_AUTH_TOKEN'].to_s.strip
if SEVERANCE_AUTH_TOKEN.empty?
  abort 'FATAL: BEACON_SEVERANCE_AUTH_TOKEN is not set. It must be the AUTH_TOKEN of the Severance ' \
        'External instance this facade calls (the callers\' token -- never Severance\'s INNIE_TOKEN).'
end
POLL_INTERVAL = ENV.fetch('BEACON_POLL_INTERVAL', '1').to_f
POLL_CEILING = ENV.fetch('BEACON_POLL_CEILING', '20').to_f

# Pre-shared key ERDERA configures when registering this facade as a Beacon
# resource (sent back to us as the `auth-key` header on every call -- see
# BeaconIndividualsQueryHandler.java in RDVP-Portal-backend, and
# ../VP-AUTH-EXPLAINED.md for the full picture). Distinct from the
# `Authorization: Bearer ...` header the VP also forwards, which carries the
# end user's own VP login session and isn't meaningful to us.
#
# This is deliberately NOT a hard access gate -- a Beacon is meant to be
# publicly queryable, and requiring this key to answer at all would mean
# only the VP could ever reach us. Instead it elevates trust: anyone can
# call /individuals and get a boolean exists-only answer; a caller
# presenting the correct key gets the fuller count response the VP needs.
#
# REQUIRED. It used to be optional, and when it was unset EVERY caller was
# treated as trusted -- an allow-by-default the same kind as Vantage6's
# GHSA-hx2w-rjmx-934x, one forgotten setting away from handing counts to
# anyone. The facade now refuses to start without it, for testing too (any
# value works there).
FACADE_AUTH_KEY = ENV['BEACON_FACADE_AUTH_KEY'].to_s.strip
if FACADE_AUTH_KEY.empty?
  abort 'FATAL: BEACON_FACADE_AUTH_KEY is not set. Set it to the pre-shared key ERDERA configures for ' \
        'this resource (for local testing, any value -- e.g. `openssl rand -hex 32`).'
end

# Constant-time comparison of the caller's `auth-key` header (hashed first, so
# neither its length nor its content leaks through response timing).
def trusted_caller?(presented)
  return false if presented.nil? || presented.empty?

  Rack::Utils.secure_compare(Digest::SHA256.digest(presented), Digest::SHA256.digest(FACADE_AUTH_KEY))
end

severance = SeveranceClient.new(
  base_url: SEVERANCE_URL,
  auth_token: SEVERANCE_AUTH_TOKEN,
  poll_interval: POLL_INTERVAL,
  poll_ceiling: POLL_CEILING
)

before do
  content_type :json
end

# Minimal Beacon Framework metadata endpoint. Scope for this facade is the
# query path only (no /catalog) -- see handoff-beacon-caresm.md decision #1.
# Left unauthenticated, per Beacon convention (and since ERDERA's VP itself
# doesn't call it before /individuals today).
get '/info' do
  {
    id: BeaconResponse::BEACON_ID,
    name: 'CARE-SM-2 Beacon (via Severance)',
    apiVersion: BeaconResponse::API_VERSION,
    facadeVersion: FACADE_VERSION,
    environment: ENV.fetch('BEACON_ENVIRONMENT', 'test'),
    organization: {
      id: 'caresm',
      name: 'CARE-SM'
    }
  }.to_json
end

# Individuals query endpoint. Built primarily against ERDERA's actual
# RDVP-Portal-backend client (see facade/lib/filter_mapper.rb and
# facade/lib/beacon_response.rb for the specifics) rather than a literal
# reading of the GA4GH Beacon v2 spec, since that's the only real caller --
# but the accepted filter shapes (ontology filter, alphanumeric AND/OR
# filter) are themselves standard Beacon v2 shapes, so a stricter client
# should also work. Publicly reachable by anyone (boolean granularity); a
# valid `auth-key` elevates the response to count granularity -- see the
# BEACON_FACADE_AUTH_KEY comment above.
post '/individuals' do
  trusted = trusted_caller?(request.env['HTTP_AUTH_KEY'])
  granularity = trusted ? 'count' : 'boolean'
  query_id = trusted ? 'individuals_count' : 'individuals_exists'

  request_body = JSON.parse(request.body.read)
  filters = request_body.dig('query', 'filters') || []
  result = FilterMapper.to_bindings(filters)

  begin
    rows = severance.query(query_id: query_id, bindings: result.bindings)
  rescue SeveranceClient::PollTimeout => e
    # Async fallback explicitly not designed yet -- see handoff decision #5.
    status 504
    return { error: 'poll_timeout', message: e.message }.to_json
  rescue SeveranceClient::QueryFailed => e
    status 502
    return { error: 'severance_query_failed', message: e.message }.to_json
  rescue SystemCallError, SocketError => e
    status 502
    return { error: 'severance_unreachable', message: e.message }.to_json
  end

  BeaconResponse.build(rows: rows, granularity: granularity, unsupported_filters: result.unsupported_filters).to_json
end

error JSON::ParserError do
  status 400
  { error: 'invalid_json' }.to_json
end

# Defense in depth: `show_exceptions, :after_handler` above means Sinatra otherwise renders its
# detailed exception page (full backtrace, file paths, gem versions) for ANY uncaught exception, in
# every environment -- there is no environment-based fallback once this setting is anything but false.
# /individuals already rescues everything SeveranceClient#query can raise explicitly, so this isn't
# currently reachable here -- but its sibling facade, ../shallot-facade, hit exactly
# this class of bug live (a route calling SeveranceClient#available_queries with no rescue around a
# connection-level failure leaked a stack trace to the caller) before its own client wrapped that
# failure and this same handler was added there. Kept here too as the safety net for the same mistake
# in any future route.
error StandardError do
  e = env['sinatra.error']
  warn "beacon-facade: unhandled #{e.class} in #{request.request_method} #{request.path_info}: #{e.message}"
  status 500
  content_type :json
  { error: 'internal_error' }.to_json
end
