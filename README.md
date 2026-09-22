# Severance-Facades

Facade services that expose [Severance](https://github.com/FAIR-Data-Systems/Severance)-backed query
results in the API shape a particular caller expects, so that caller needs no code change of its own.
Both facades only ever talk to Severance External's own public API (`available_queries`, `queries`,
`jobs/:uuid`) -- neither reads a `.rq` file directly, and neither has any other dependency on the
Severance repo itself.

- **[`shallot-facade`](shallot-facade/)** -- domain-agnostic. Makes Severance look like a
  [Shallot](https://github.com/wilkinsonlab/shallot)/GRLC-shaped service: one `GET /<query_id>` route
  per query, built dynamically from whatever queries Severance Internal has installed. Works for any
  data model, unmodified.
- **[`beacon-facade`](beacon-facade/)** -- domain-specific to CARE-SM-2. Makes Severance look like a
  GA4GH Beacon v2 API for CARE-SM-2 patient data (e.g. for ERDERA's Virtual Platform). Hardcoded query
  IDs, a CARE-SM-2 ontology filter-mapper; see its own `handoff-beacon-caresm.md` and
  `severance-queries/README.md` for the design rationale and query binding contract.

See each facade's own `README.md` for setup, endpoints, and deployment detail.

## Security pipeline

`Security/security-patch.sh` builds both images fresh from source, OS-patches them, pushes, Trivy-scans,
attempts automated Ruby gem CVE patches, and keeps both `docker-compose.yml` files' image tags aligned
automatically -- no manual step, no cross-repo cloning (both facades live in this one repo). See
`Security/VULNERABILITY_TRIAGE.md` for the triage process and `vulnerability-register.csv` for the
current disposition of every known finding.

## History

Both facades moved here from other repos on 2026-09-22 -- `shallot-facade` from
[`Severance`](https://github.com/FAIR-Data-Systems/Severance) (`facades/shallot-facade/`), `beacon-facade`
from [`CARE-Semantic-Model-Version-2`](https://github.com/wilkinsonlab/CARE-Semantic-Model-Version-2)
(`implementation/Beacon2/facade/`, plus its `severance-queries/` and `handoff-beacon-caresm.md`). Full
pre-move commit history for both is preserved in this repo's own git log (`git log -- shallot-facade/`
/ `git log -- beacon-facade/`). See `CHANGELOG.md` for why.
