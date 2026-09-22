# Beacon facade for CARE-SM-2 over Severance

**Version: see [`VERSION`](VERSION)**. The running facade reports this
same value at `GET /info` as `facadeVersion` (read from this file at boot
— see `app.rb`), and the Docker image bakes it in as an
`org.opencontainers.image.version` label (see the Dockerfile and "Docker"
section below).

A Sinatra app implementing the query path of a GA4GH Beacon v2-shaped
API, backed by CARE-SM-2 patient data via
[Severance](https://github.com/FAIR-Data-Systems/Severance) as the secure
query relay. See [`handoff-beacon-caresm.md`](handoff-beacon-caresm.md) for
the original design rationale and open questions, and
[`severance-queries/README.md`](severance-queries/README.md) for the query
binding contract. Moved here from
[`CARE-Semantic-Model-Version-2`](https://github.com/wilkinsonlab/CARE-Semantic-Model-Version-2)'s
`implementation/Beacon2/facade`, alongside its sibling
[`shallot-facade`](../shallot-facade) — see this repo's `CHANGELOG.md` for
details; full pre-move commit history is preserved in this repo's own git
log.

**Scope: query path only. There is no `/catalog`.**

**Running this facade does NOT give you access to any data on its own.** It can only answer for the two
named queries (`individuals_exists`, `individuals_count`) that the data provider has installed on
Severance Internal — see step 3 below. If those queries aren't installed, this facade has nothing to
answer with.

**Built for ERDERA's real client, not a literal reading of the GA4GH spec.** Reading ERDERA's
`RDVP-Portal-backend`/`RDVP-Portal-frontend` source (the only real caller this facade will ever have)
showed its Beacon requests and expected responses deviate from the GA4GH Beacon v2 spec in several
ways. This facade answers that real client correctly first; spec compliance is a secondary, best-effort
goal where it doesn't conflict. **You need to know these deviations if you're maintaining or debugging
this facade:**

- **No `requestedGranularity` is ever sent by ERDERA's client.** It always reads both
  `responseSummary.exists` and `responseSummary.numTotalResults` and expects both populated. This
  facade does NOT gate granularity on a request field at all — it gates on trust (see the `auth-key`
  point below). A real Beacon-spec client explicitly asking for a boolean-only answer gets no different
  treatment than any other untrusted caller.
- The response also needs a `response.resultSets[]` array (not just `responseSummary`), and an
  `info.warnings.unsupportedFilters` list when applicable — see `IndividualsResponseBody.java` /
  `BeaconResponseBodyResponseSection.java` in RDVP-Portal-backend.
- **Auth is a per-resource pre-shared `auth-key` header**, configured on ERDERA's side when they
  register this facade as a resource — NOT a bearer token, and NOT a standard Beacon security scheme.
  This is deliberate, not a gap: a Beacon is meant to be publicly queryable, so **anyone CAN call
  `/individuals` and get a boolean `exists`-only answer** — only a caller presenting the correct
  `auth-key` gets the fuller count response the VP needs. See `../VP-AUTH-EXPLAINED.md` for the full
  picture, including why neither this key nor the VP's own forwarded end-user token amounts to real
  authorization of *who* gets a count.
- `sex` and `disease` filters CAN arrive with **multiple** values (OR semantics), but Severance's
  binding substitution is scalar — **only the first value is honored**; the rest are reported back in
  `info.warnings.unsupportedFilters`. See `../severance-queries/README.md` for why this is a
  Severance-level limit, not something fixable in this facade alone.
- Age-like filters (`ageThisYear`, `symptomOnset`, `ageAtDiagnosis`) always arrive as a `>=`/`<=` range,
  never an exact value. `ageThisYear` in particular is tagged with Birthyear's own NCIT code
  (`obo:NCIT_C83164`) but its value is an actual age — `FilterMapper` inverts it into a birth-year
  range.
- Only 5 of the 7 CARE-SM-2 filters (`disease`, `sex`, birthyear via ageThisYear, `age_symptom_onset`,
  `age_diagnosis`) are ever populated by the VP today. `symptom` and `gene_variant` are supported for a
  future spec-compliant caller but untested against a real request.

## Setup

**Do these steps in order:**

1. `bundle install`
2. **Copy `env_template` to `.env`.** Edit:
   - `BEACON_SEVERANCE_URL` / `BEACON_SEVERANCE_AUTH_TOKEN` -- must match your Severance External
     deployment exactly.
   - `BEACON_FACADE_AUTH_KEY` -- set this to whatever pre-shared key ERDERA configures for this
     resource. All env vars here are `BEACON_`-prefixed on purpose, so they can't collide with
     unrelated ones on a host that also runs Severance (or anything else) alongside this facade.
3. **Install `../severance-queries/individuals_exists.rq` and `individuals_count.rq` into your
   Severance Internal's `./queries` folder** (see `../severance-queries/README.md`). **This facade
   cannot answer anything until you do this.**
4. `bundle exec rackup` (reads `BEACON_PORT`/`BEACON_BIND` from the environment, defaulting to
   `4567`/`0.0.0.0`)

## Running it with Docker

    docker compose up

(after step 2 above -- `docker-compose.yml` reads `.env`, and `BEACON_PORT` if you changed it from the
default).

**DO NOT edit `image:` in `docker-compose.yml` by hand.** It's hardened the same way as Severance's own
`external/`/`internal/` compose files and its sibling [`shallot-facade`](../shallot-facade)'s
(`restart: always`, `security_opt: no-new-privileges`, `cap_drop: [ALL]`, `mem_limit`/`cpus`
ceilings), and it's kept up to date automatically: **`Security/security-patch.sh`** (see
`../Security/`) builds this image fresh from source, OS-patches it, pushes
`fairdatasystems/beaconfacade:<date>`, Trivy-scans it, attempts an automated Ruby gem CVE patch, and
writes the freshly-pushed tag straight into this file itself, committing and pushing that bump
directly.

## Endpoints

- **`GET /info`** -- minimal Beacon Framework metadata stub. No authentication needed. Includes
  `facadeVersion` (this codebase's own version) alongside `apiVersion` (the Beacon API shape being
  emulated) -- see the Version section above.
- **`POST /individuals`** -- the individuals query. **Publicly reachable by anyone** -- there is no
  login required to call it. Body, matching what ERDERA's VP actually sends (see
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

  **What you get back depends on whether the caller presents a valid `auth-key` header** matching
  `BEACON_FACADE_AUTH_KEY` (if `BEACON_FACADE_AUTH_KEY` is left unset, every caller is trusted -- only
  do this for local testing). See `../VP-AUTH-EXPLAINED.md` for why this is deliberately not a hard
  access gate. **Without the correct `auth-key`, you get a boolean-only response:**

  ```json
  {
    "meta": { "apiVersion": "v2.0.0", "beaconId": "org.caresm.beacon-caresm", "returnedGranularity": "boolean" },
    "responseSummary": { "exists": true },
    "response": { "resultSets": [{ "id": "care-sm-2-registry", "type": "dataset", "exists": true, "info": {} }] }
  }
  ```

  **With the correct `auth-key`** (the VP, today), you get the fuller count response the VP client
  actually needs:

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

  An `info.warnings.unsupportedFilters` array is added only when a filter couldn't be fully honored
  (e.g. a multi-valued sex/disease filter).

## Code structure (for developers maintaining this facade)

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
