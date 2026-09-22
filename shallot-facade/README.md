# shallot-facade

**Version: see [`VERSION`](VERSION).**

A Sinatra app that makes [Severance](https://github.com/FAIR-Data-Systems/Severance) look like a
[Shallot](https://github.com/wilkinsonlab/shallot) service to any caller: one synchronous
`GET /<query_id>?param=...` route per query Severance Internal has installed, plus a Swagger 2.0
document describing them, built dynamically from Severance's own `GET /severance/available_queries`
catalogue.

**This does NOT use any Shallot or GRLC code.** Shallot's own query-annotation format and
variable-naming convention come from [GRLC](https://github.com/CLARIAH/grlc), referenced here only for
that -- GRLC's own server has a known, unpatched security history, which is exactly why FLAIR-GG runs
the hardened Shallot fork instead, and why this facade only mimics Shallot's interface, never its
code. **You CAN point an existing Shallot-speaking caller at this facade with no code change of its
own** -- register it in the FAIR Data Point exactly like a Shallot query (`dcat:endpointURL` =
`<this facade>/<query_id>`, `dcat:endpointDescription` = `<this facade>/openapi.json`, same
`dcterms:type` as the equivalent Shallot query).

**Domain-agnostic on purpose.** Unlike its sibling [`beacon-facade`](../beacon-facade)
(CARE-SM-2-specific: hardcoded query IDs, an ontology filter-mapper), this facade has zero knowledge
of any particular data model. **You CAN use it unmodified** for FLAIR-GG's queries, CARE-SM-2's, or
anyone else's -- it only ever talks to Severance External's own public API (`available_queries`,
`queries`, `jobs/:uuid`). **It CANNOT read a `.rq` file directly**, and it needs nothing else from you
beyond a working Severance deployment.

**Running this facade does NOT give you access to any data on its own.** It only exposes queries that
the data provider has already approved and installed on Severance Internal. If the query you need
isn't there yet, you must get it added before this facade can do anything with it.

## Setup

**Do these steps in order:**

1. `bundle install`
2. **Copy `env_template` to `.env`.** Edit:
   - `SHALLOT_FACADE_SEVERANCE_URL` / `SHALLOT_FACADE_SEVERANCE_AUTH_TOKEN` -- must match your Severance
     External deployment exactly.
   - `SHALLOT_FACADE_BASE_URL` -- this facade's own externally-reachable base URL. **This has to be
     exactly right** -- see `GET /openapi.json` below for why.
3. **Install your query `.rq` files into Severance Internal's `./queries` folder, as usual.** Nothing
   about them needs to change for this facade -- it only reads what Internal has already parsed and
   already pushed to External's `available_queries`. You CANNOT make a query available through this
   facade any other way.
4. **Your Severance External must be running a version that includes the `before`-filter fix** (shipped
   since 2026-09 -- see the top-level `CHANGELOG.md`'s "Fixed" entry in the Severance repo). If it's an
   older, unpatched deployment, `GET /severance/jobs/:uuid` and `GET /severance/available_queries` will
   be unreachable for this facade, and nothing will work.
5. `bundle exec rackup` (reads `SHALLOT_FACADE_PORT`/`SHALLOT_FACADE_BIND` from the environment,
   defaulting to `4567`/`0.0.0.0`)

## Running it with Docker

    docker compose up

(after step 2 above -- `docker-compose.yml` reads `.env`, and `SHALLOT_FACADE_PORT` if you changed it
from the default).

**DO NOT edit `image:` in `docker-compose.yml` by hand.** It's hardened the same way as Severance's own
`external/` and `internal/` compose files (`restart: always`, `security_opt: no-new-privileges`,
`cap_drop: [ALL]`, `mem_limit`/`cpus` ceilings), and it's kept up to date automatically:
**`Security/security-patch.sh`** (see `../Security/`) builds this image fresh from source, OS-patches
it, pushes `fairdatasystems/shallotfacade:<date>`, Trivy-scans it, attempts an automated Ruby gem CVE
patch, and writes the newly patched tag straight into this file itself, committing and pushing that
bump directly.

You CAN still build and run a local copy yourself while waiting on a patch run:
`docker build -t fairdatasystems/shallotfacade:local .`

## Configuration reference

| Env var | Meaning |
| --- | --- |
| `SHALLOT_FACADE_PORT` / `SHALLOT_FACADE_BIND` | listen port/address, default `4567`/`0.0.0.0` |
| `SHALLOT_FACADE_BASE_URL` | this facade's own externally-reachable base URL -- see `GET /openapi.json` below |
| `SHALLOT_FACADE_SEVERANCE_URL` / `SHALLOT_FACADE_SEVERANCE_AUTH_TOKEN` | the Severance External this facade submits queries to, and its Bearer token |
| `SHALLOT_FACADE_POLL_INTERVAL` / `SHALLOT_FACADE_POLL_CEILING` | blocking poll loop tuning while waiting for Severance Internal to answer a job |
| `SHALLOT_FACADE_PRODUCES` | content type(s) this Severance deployment's `RESULT_FORMAT` actually returns -- documentation only, in the OpenAPI doc |

## Endpoints

- **`GET /`** -- minimal banner (facade version, known query IDs). No authentication needed.
- **`GET /openapi.json`** -- a Swagger 2.0 document, one path per known query, built from Severance's
  `available_queries` catalogue. This is what `dcat:endpointDescription` should point to. Its
  `host`/`basePath`/`schemes` are derived from `SHALLOT_FACADE_BASE_URL` -- **this must match the
  scheme/host/path prefix a caller registers as `dcat:endpointURL`** for the corresponding query
  (`<SHALLOT_FACADE_BASE_URL>/<query_id>`), or a caller that fetches this doc (like the VP) won't be
  able to find the operation's parameters.
- **`GET /<query_id>?param1=val1&param2=val2...`** -- one route per catalogue entry, e.g. `GET
  /IUCN_categories`, `GET /species_location?speciesname=Arabidopsis`. Query-string parameter names must
  match Severance's own binding names exactly -- there is no translation step.
  - **`404`** if `query_id` doesn't match any known query.
  - **`502`** if Severance itself rejects the query or is unreachable.
  - **`504`** if the poll ceiling (`SHALLOT_FACADE_POLL_CEILING`) is reached before an answer comes
    back.

**This facade does not require any caller-facing authentication of its own** -- it holds its own
Severance `AUTH_TOKEN` internally (`SHALLOT_FACADE_SEVERANCE_AUTH_TOKEN`) and never exposes it to
callers.

## Code structure (for developers maintaining this facade)

- `app.rb` -- routes; boots a `SeveranceClient` and a `QueryCatalogue`, serves `/`, `/openapi.json`, and
  the dynamic `/:query_id` route.
- `lib/severance_client.rb` -- fetches `available_queries`; owns the submit -> poll -> fetch cycle for
  a single query. Returns results as opaque bytes plus a content type -- unlike its Beacon-facade
  sibling, this never parses result rows into a Ruby structure, since it isn't reshaping anything.
- `lib/query_catalogue.rb` -- caches `available_queries` by `query_id`, refreshing on a lookup miss
  (a query might have just been installed on Internal) rather than on a timer -- no background thread,
  nothing to configure.
- `lib/openapi_builder.rb` -- catalogue -> Swagger 2.0 document.

## Known gaps

- `QueryCatalogue`'s refresh-on-miss means a query *removed* from Internal stays visible here (and
  routable, until Severance itself rejects the `query_id`) until the process restarts or another
  lookup happens to trigger a refresh that drops it. Not a correctness problem (Severance is still the
  source of truth for whether a query actually runs), just a stale-listing edge case.
