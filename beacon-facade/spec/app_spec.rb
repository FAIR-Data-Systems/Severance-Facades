# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'json'

# app.rb builds its SeveranceClient at load time but makes no network call until a query runs; the
# examples below stub SeveranceClient#query. The token is required at boot (app.rb aborts without it).
ENV['BEACON_SEVERANCE_AUTH_TOKEN'] ||= 'b' * 40
# Sinatra restricts Host headers only in development (rack-test sends example.org).
ENV['APP_ENV'] = 'test'
require_relative '../app'

RSpec.describe 'beacon-facade' do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  it 'answers GET /info' do
    get '/info'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to include('apiVersion')
  end

  it 'still answers a JSON POST /individuals' do
    allow_any_instance_of(SeveranceClient).to receive(:query).and_return([])
    post '/individuals', { query: { filters: [] } }.to_json, { 'CONTENT_TYPE' => 'application/json' }
    expect(last_response.status).to eq(200)
  end

  it 'refuses multipart bodies before anything parses them' do
    expect(Rack::Multipart::Parser).not_to receive(:parse)
    expect(Rack::Multipart).not_to receive(:parse_multipart)
    body = "--b\r\nContent-Disposition: form-data; name=\"query\"\r\n\r\n{}\r\n--b--\r\n"

    post '/individuals', body, { 'CONTENT_TYPE' => 'multipart/form-data; boundary=b' }
    expect(last_response.status).to eq(415)
  end

  it 'refuses to start without BEACON_SEVERANCE_AUTH_TOKEN (no more YesItsMe fallback)' do
    out = IO.popen({ 'BEACON_SEVERANCE_AUTH_TOKEN' => nil },
                   ['ruby', '-e', "require '#{File.expand_path('../app', __dir__)}'; puts 'BOOTED'"],
                   err: %i[child out], &:read)
    expect(out).to include('FATAL: BEACON_SEVERANCE_AUTH_TOKEN is not set')
    expect(out).not_to include('BOOTED')
  end
end
