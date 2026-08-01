# frozen_string_literal: true

# Translates a Severance result set into a Beacon-shaped response.
# Query-path only (see handoff-beacon-caresm.md).
#
# Two granularity tiers, gated by whether the caller presented a valid
# `auth-key` (see app.rb) -- a Beacon is meant to be publicly queryable, so
# an untrusted/anonymous caller still gets a real answer, just a less
# revealing one:
#
# - 'count' (trusted, i.e. the VP): both `exists` and `numTotalResults`,
#   plus a `resultCount` in the resultSet. ERDERA's actual VP client never
#   sends `requestedGranularity` and always reads both summary fields (see
#   IndividualsResponseBody.java / BeaconResponseBodySummarySection.java in
#   RDVP-Portal-backend) -- there's no negotiation to honor, it always
#   wants this tier.
# - 'boolean' (anyone else): just `exists`, no counts -- avoids the
#   small-number reidentification risk flagged in the original handoff for
#   rare disease data, while still letting any real Beacon client discover
#   whether a match exists at all.
#
# Also builds `response.resultSets[]` in addition to `responseSummary`,
# since that's what the VP client actually deserializes
# (BeaconResponseBodyResponseSection.java / IndividualsResultSet.java).
module BeaconResponse
  BEACON_ID = 'org.caresm.beacon-caresm'
  API_VERSION = 'v2.0.0'
  # TODO: replace with the real dataset id ERDERA assigns once this
  # facade is registered as a resource in the VP.
  DATASET_ID = 'care-sm-2-registry'

  # @param rows [Array<Hash>] rows from SeveranceClient#query -- a single
  #   { "count" => n } row for granularity 'count', or zero-or-one rows
  #   with a "person" column for granularity 'boolean'
  # @param granularity ['count', 'boolean']
  # @param unsupported_filters [Array<String>] human-readable notes about any
  #   request filters that couldn't be honored (see FilterMapper)
  def self.build(rows:, granularity:, unsupported_filters: [])
    summary, result_set = granularity == 'count' ? count_tier(rows) : boolean_tier(rows)

    body = {
      meta: meta(granularity),
      responseSummary: summary,
      response: { resultSets: [result_set.merge(id: DATASET_ID, type: 'dataset', info: contact_info)] }
    }
    body[:info] = { warnings: { unsupportedFilters: unsupported_filters } } unless unsupported_filters.empty?
    body
  end

  def self.count_tier(rows)
    count = rows.first&.values&.first.to_i
    exists = count.positive?
    [{ exists: exists, numTotalResults: count }, { exists: exists, resultCount: count }]
  end

  def self.boolean_tier(rows)
    exists = !rows.empty?
    [{ exists: exists }, { exists: exists }]
  end

  def self.meta(granularity)
    {
      apiVersion: API_VERSION,
      beaconId: BEACON_ID,
      returnedGranularity: granularity
    }
  end

  def self.contact_info
    {
      contactPoint: ENV.fetch('BEACON_CONTACT_POINT', nil),
      contactEmail: ENV.fetch('BEACON_CONTACT_EMAIL', nil),
      contactURL: ENV.fetch('BEACON_CONTACT_URL', nil)
    }.compact
  end
end
