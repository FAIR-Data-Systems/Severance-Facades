# Beacon facade for CARE-SM-2 over Severance

**Version: see [`VERSION`](VERSION)**, kept in sync with
[`../VERSION`](../VERSION) (the overall Beacon2 project version). The
running facade reports this same value at `GET /info` as `facadeVersion`
(read from this file at boot — see `app.rb`), and the Docker image bakes
it in as an `org.opencontainers.image.version` label (see the Dockerfile
and "Docker" section below). Bump both `VERSION` files together when
making a real release; nothing auto-syncs them.

A Sinatra app implementing the query path of a GA4GH Beacon v2-shaped
API, backed by CARE-SM-2 patient data via
[Severance](https://github.com/FAIR-Data-Systems/Severance) as the secure
query relay. See `../handoff-beacon-caresm.md` for the original design
rationale and open questions.

Scope: query path only. No `/catalog`.

**Built primarily for ERDERA's actual client, not the GA4GH spec.**
Reading ERDERA's `RDVP-Portal-backend` / `RDVP-Portal-frontend` source
(the only real caller this facade will ever have) showed its Beacon
requests and expected responses deviate from the GA4GH Beacon v2 spec in
several ways. This facade is built to answer that real client correctly
first; spec compliance is a secondary, best-effort goal where it doesn't
conflict. Concretely:

- No `requestedGranularity` is ever sent by ERDERA's client — it always
  reads both `responseSummary.exists` and `responseSummary.numTotalResults`
  and expects both populated. This facade doesn't gate granularity on a
  request field at all; instead it gates on trust (see the `auth-key`
  point below) — a real Beacon-spec client asking for boolean explicitly
  isn't supported any differently than an untrusted caller getting one by
  default.
- The response also needs a `response.resultSets[]` array (not just
  `responseSummary`), and an `info.warnings.unsupportedFilters` list when
  applicable — see `IndividualsResponseBody.java` /
  `BeaconResponseBodyResponseSection.java` in RDVP-Portal-backend.
- Auth is a per-resource pre-shared `auth-key` header, configured on
  ERDERA's side when they register this facade as a resource — not a
  bearer token or standard Beacon security scheme. Deliberately **not** a
  hard access gate: a Beacon is meant to be publicly queryable, so anyone
  can call `/individuals` and get a boolean `exists`-only answer; only a
  caller presenting the correct `auth-key` gets the fuller count response
  the VP needs. See `../VP-AUTH-EXPLAINED.md` for the full picture,
  including why neither this key nor the VP's own forwarded end-user
  token amounts to real authorization of *who* gets a count.
- `sex` and `disease` filters can arrive with **multiple** values (OR
  semantics). Severance's binding substitution is scalar, so only the
  first value is honored; the rest are reported back in
  `info.warnings.unsupportedFilters`. See
  `../severance-queries/README.md` for why this is a Severance-level
  constraint, not something fixable in this facade alone.
- Age-like filters (`ageThisYear`, `symptomOnset`, `ageAtDiagnosis`)
  always arrive as a `>=`/`<=` range, not an exact value. `ageThisYear` in
  particular is tagged with Birthyear's own NCIT code
  (`obo:NCIT_C83164`) but its value is an actual age — `FilterMapper`
  inverts it into a birth-year range.
- Only 5 of the 7 CARE-SM-2 filters (`disease`, `sex`, birthyear via
  ageThisYear, `age_symptom_onset`, `age_diagnosis`) are ever populated by
  the VP today. `symptom` and `gene_variant` are supported for a future
  spec-compliant caller but untested against a real request.

## Setup

1. `bundle install`
2. Copy `env_template` to `.env` and edit `BEACON_SEVERANCE_URL` /
   `BEACON_SEVERANCE_AUTH_TOKEN` to match your Severance External
   deployment, and set `BEACON_FACADE_AUTH_KEY` to whatever pre-shared key
   ERDERA configures for this resource. All env vars are `BEACON_`-prefixed
   on purpose, so they can't collide with unrelated ones on a host that
   also runs Severance (or anything else) alongside this facade.
3. Install `../severance-queries/individuals_exists.rq` and
   `individuals_count.rq` into your Severance Internal's `./queries` folder
   (see `../severance-queries/README.md`).
4. `bundle exec rackup` (reads `BEACON_PORT`/`BEACON_BIND` from the
   environment, defaulting to `4567`/`0.0.0.0`)

## Endpoints

- `GET /info` -- minimal Beacon Framework metadata stub. Unauthenticated.
  Includes `facadeVersion` (this codebase's own version) alongside
  `apiVersion` (the Beacon API shape being emulated) -- see the Version
  section above.
- `POST /individuals` -- individuals query, publicly reachable by anyone.
  Body, matching what ERDERA's VP actually sends (see
  `BeaconIndividualsQueryHandler.java` in RDVP-Portal-backend):

  ```json
  {
    "meta": { "apiVersion": "v0.2" },
    "query": {
      "filters": [
        { "id": ["ordo:Orphanet_730"] },
        { "id": "obo:NCIT_C28421", "operator": "=", "value": ["NCIT_C16576"] },
        { "id": "obo:NCIT_C83164", "operator": ">=", "value": "10" },
        { "id": "obo:NCIT_C83164", "operator": "<=", "value": "40" }
      ]
    }
  }
  ```

  The response's granularity depends on whether the caller presents a
  valid `auth-key` header matching `BEACON_FACADE_AUTH_KEY` (unset = every
  caller trusted, e.g. for local testing) -- see
  `../VP-AUTH-EXPLAINED.md` for why this is deliberately not a hard
  access gate. Anyone without it gets a boolean-only response:

  ```json
  {
    "meta": { "apiVersion": "v2.0.0", "beaconId": "org.caresm.beacon-caresm", "returnedGranularity": "boolean" },
    "responseSummary": { "exists": true },
    "response": { "resultSets": [{ "id": "care-sm-2-registry", "type": "dataset", "exists": true, "info": {} }] }
  }
  ```

  A caller presenting the correct `auth-key` (the VP, today) gets the
  fuller count response the VP client actually needs:

  ```json
  {
    "meta": { "apiVersion": "v2.0.0", "beaconId": "org.caresm.beacon-caresm", "returnedGranularity": "count" },
    "responseSummary": { "exists": true, "numTotalResults": 3 },
    "response": {
      "resultSets": [
        { "id": "care-sm-2-registry", "type": "dataset", "exists": true, "resultCount": 3, "info": {} }
      ]
    }
  }
  ```

  An `info.warnings.unsupportedFilters` array is added only when a filter
  couldn't be fully honored (e.g. a multi-valued sex/disease filter).

## Structure

- `app.rb` -- routes; checks `auth-key`, parses the request, calls
  Severance, shapes the response.
- `lib/filter_mapper.rb` -- real ERDERA filter ids (CURIEs like
  `obo:NCIT_C28421`) -> the CARE-SM-2 Severance binding contract, including
  the ontology-filter (disease) and AND/OR (sex, age ranges) shapes, and
  the ageThisYear -> birthyear inversion.
- `lib/severance_client.rb` -- submit -> poll -> fetch cycle against
  Severance External. Raises `PollTimeout` if the poll ceiling is hit
  (surfaced as HTTP 504 -- no async Beacon handover is implemented, per
  the handoff's decision #5).
- `lib/beacon_response.rb` -- Severance result rows -> the
  `responseSummary` + `response.resultSets[]` + `info.warnings` JSON shape
  ERDERA's client actually deserializes.

## Known gaps

- Multi-valued `sex`/`disease` filters collapse to their first value —
  see `../severance-queries/README.md`.
- The `auth-key` / boolean-vs-count split only ever distinguishes "the VP"
  from "everyone else" — there's no way to recognize a third party (e.g. a
  genuinely ethics-approved researcher not going through the VP) as
  trustworthy for count access. See `../VP-AUTH-EXPLAINED.md`'s section on
  LS-AAI validation for why that's a real open question, deliberately not
  implemented yet.
- `/configuration`, `/entry_types`, `/filtering_terms` not implemented --
  ERDERA's client doesn't call them today; add if that changes.
- None of this has been run against a real Severance + CARE-SM-2
  triplestore yet -- only smoke-tested against a stub. See
  `../severance-queries/README.md` for the specific modeling assumptions
  that still need validating.
- The Docker image build itself is unverified in this environment (its
  package-manager network access was blocked by a sandbox policy, not a
  problem with the image) -- worth a real `docker build` before relying on
  it.
