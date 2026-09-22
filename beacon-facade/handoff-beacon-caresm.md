# Handoff: Beacon API over Severance (ERDERA rare disease use case)

Status: architecture plan only — no code written yet. This doc is the starting
point for tomorrow's Claude Code session.

## Goal

Implement a GA4GH Beacon v2-compatible query endpoint that ERDERA's Virtual
Platform can call, backed by CARE-SM-2 patient data, using Severance
(FAIR-Data-Systems/Severance) as the secure query relay to the internal
triplestore. Only the query path is in scope — no `/catalog`.

Reference implementation for filter→SPARQL mapping ideas (NOT for the
async/named-query pattern, which Severance replaces):
https://github.com/CARE-SM/beaconAPI4CARESM

## Architecture

```
ERDERA Virtual Platform
        |  Beacon v2 query (JSON, arbitrary filter combination)
        v
Beacon facade (Sinatra, new component)
        |  maps Beacon filters -> Severance named-query bindings
        |  POSTs to Severance External, then blocking-polls for result
        v
Severance External  <---- polls every few sec ----  Severance Internal
        |                                                    |
        |  (near-synchronous: default install,                |
        |   internal polls external every few sec)            v
        |                                          Triplestore (CARE-SM-2, quads)
        v
Beacon facade returns Beacon-shaped JSON response to ERDERA VP
```

Key property: the facade owns the entire submit -> poll -> respond cycle
within a single incoming Beacon HTTP request. ERDERA never sees Severance's
async job mechanics directly.

## Decisions made

1. **Scope**: query path only. No `/catalog`. Beacon Framework endpoints
   (`/info`, `/configuration`, etc.) TBD — probably still needed for VP
   compatibility, confirm during implementation.

2. **Data model**: all users are CARE-SM-2. This lets us guarantee the
   shape of the query for any Beacon request — no per-institution schema
   variance to handle.

3. **Named query design — two queries, shared filter contract, not one:**
   - `individuals_exists` — `ASK` (or `SELECT ... LIMIT 1`) — boolean granularity
   - `individuals_count` — `SELECT (COUNT(DISTINCT ?patient) AS ?count)` — count granularity
   - Both take the **same 7 optional/unbound-safe filter variables**:
     `sex`, `disease`, `symptom`, `gene_variant`, `birthyear`,
     `age_symptom_onset`, `age_diagnosis` (mirrors beaconAPI4CARESM's filter set —
     confirm this is still the full CARE-SM-2 filter list, may have grown).
   - Rejected: one named query per filter combination (combinatorial
     explosion, 2^7 = 128+, no security benefit since values are always
     user-supplied bindings regardless).
   - The templates live only inside Severance Internal (per Severance's
     model — query text never crosses to External). Each template uses
     conditional patterns per variable, e.g.
     `FILTER(!BOUND(?sex) || ?patientSex = ?sex)`, so a single template
     handles any combination of present/absent filters.
   - **TODO**: keep the two templates' `WHERE` patterns in lockstep — if a
     filter is added/changed, edit both.

4. **Facade responsibility**: the Sinatra facade (new Ruby/Sinatra app,
   following the usual stack — Greg Kellogg RDF gems if any local RDF
   handling is needed, quads/named graphs, content negotiation for
   `text/html` / `application/json` / `application/ld+json`) is responsible
   for:
   - Parsing incoming Beacon v2 request, extracting filters + requested
     granularity (`boolean` vs `count`)
   - Mapping filters to the shared binding contract
   - Choosing `individuals_exists` vs `individuals_count` by granularity
   - POST to Severance External `/severance/queries`
   - Blocking poll loop against the returned `Location` (suggest ~1s
     interval, ~15-20s ceiling given internal polls every few sec by
     default — tune during implementation)
   - Translating the Severance result (CSV/JSON per `RESULT_FORMAT`) into
     a Beacon-shaped response

5. **Async fallback**: explicitly NOT designing this now. If the poll
   ceiling is ever hit, stub it (TODO / error response) rather than
   building real Beacon async handover — deployment's near-sync polling
   makes this a rare edge case for now.

## Open questions for later (not blocking tomorrow's start)

- Should unauthenticated ERDERA queries be boolean-only, with count
  reserved for a trusted/authenticated tier? (Small-number
  reidentification risk in rare disease — CARE-SM's existing Beacon impl
  only returns counts today, worth revisiting.)
- Confirm current full CARE-SM-2 filter variable list against the 7
  inherited from CARE-SM v1/beaconAPI4CARESM — may have changed since we
  designed CARE-SM-2.
- Beacon Framework metadata endpoints (`/info`, `/configuration`,
  `/entry_types`, `/filtering_terms`) — needed for VP compatibility?
  Confirm against ERDERA's actual Beacon client requirements.
- NanoPub provenance for query audit trail (mentioned in earlier
  conversation, not yet designed) — worth revisiting once the core path
  works.

## Next steps for Claude Code session

1. Scaffold the Beacon facade Sinatra app (new repo or subdir — decide
   location).
2. Draft the two SPARQL templates (`individuals_exists`,
   `individuals_count`) against CARE-SM-2, following the shared filter
   pattern.
3. Register them as named queries in a Severance Internal deployment
   (queries-metadata + query files, per Severance's `external/README.md`
   / `internal/README.md` install docs).
4. Build the filter-mapping + polling logic in the facade.
5. Wire up a test ERDERA-shaped Beacon request end-to-end against a local
   Severance + CARE-SM-2 test triplestore.
