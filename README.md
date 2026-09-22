# Severance-Facades

Facade services that expose [Severance](https://github.com/FAIR-Data-Systems/Severance)-backed query
results in the API shape a particular caller expects, so that caller needs no code change of its own.
Facades  in this repository only ever talk to Severance External's own public API (`available_queries`, `queries`,
`jobs/:uuid`) -- none of them read a `.rq` file directly, and none have any other dependency on the
Severance repo itself.  Note that, in all cases, you will need to negotiate with the data provider to include your .rq named template in their repository of acceptable queries! Creating a Facade does not give you access to data!  It only provides the interface into a query that has already been approved and registered by the data provider (i.e. queries that exist in Severance Internal)

- **[`shallot-facade`](shallot-facade/)** -- domain-agnostic. Makes Severance look like a
  [Shallot](https://github.com/markwilkinson/Shallot)/GRLC-shaped service: one `GET /<query_id>` route
  per query, built dynamically from whatever queries Severance Internal has installed. Works for any
  data model, unmodified.  NOTE:  This does NOT use any Shallot or GRLC code, because those codebases are not as secure as Severance!  We only mimik the GRLC and Shallot interface calls in this facade.  However, if your query exists in the Internal component, your normal calls to GRLC or Shallot will be successful.
- **[`beacon-facade`](beacon-facade/)** -- domain-specific to CARE-SM-2. Makes Severance look like a
  GA4GH Beacon v2 API for CARE-SM-2 patient data (e.g. for ERDERA's Virtual Platform). Hardcoded query
  IDs, a CARE-SM-2 ontology filter-mapper.
  
See each facade's own `README.md` for setup, endpoints, and deployment detail.

## Security pipeline

`Security/security-patch.sh` builds both images fresh from source, OS-patches them, pushes, Trivy-scans,
attempts automated Ruby gem CVE patches, and keeps both `docker-compose.yml` files' image tags aligned
automatically -- no manual step, no cross-repo cloning (both facades live in this one repo). See
`Security/VULNERABILITY_TRIAGE.md` for the triage process and `vulnerability-register.csv` for the
current disposition of every known finding.

## How to implement a new facade

A facade is a thin translation layer: it speaks some external API shape (Beacon, Shallot/GRLC,
whatever a specific caller needs) on one side, and **only ever talks to Severance External's public
API** on the other -- never a `.rq` file, never Severance Internal, never the triplestore directly.
Both existing facades follow the same shape; copy whichever is closer to your case
(`shallot-facade` if domain-agnostic, `beacon-facade` if it needs to know about a specific data
model) rather than starting from a blank Sinatra app.

### The three calls you have

A `SeveranceClient`-style wrapper (see either facade's `lib/severance_client.rb`) is just three HTTP
calls against Severance External's `SEVERANCE_URL`:

1. `GET /severance/available_queries` -- the catalogue: every query Severance Internal has installed,
   its bindings, and metadata. Build your routes/OpenAPI doc/response shaping from this, dynamically
   (`shallot-facade`) or against a hardcoded subset your facade knows about (`beacon-facade`) --
   either way, don't hardcode a query's SPARQL or binding names anywhere in the facade itself, only
   its `query_id` and how to map *your* API's filters onto that query's declared bindings.
2. `POST /severance/queries` with `{query_id, bindings}` -- submits the query, returns a `location` to
   poll.
3. `GET` that `location` (a job URL) -- poll until the result is ready.

### Required Sinatra boilerplate (copy, don't rederive)

Every facade needs these, copied near-verbatim from either existing one's top of `app.rb`:

- **The `Rack::Protection::HostAuthorization` monkeypatch.** Sinatra 4.x/rack-protection 4.x rejects
  any Host header outside a small built-in allowlist with a bare `403 Host not permitted`, before your
  route code even runs. `set :protection, except: :host_authorization` does **not** reliably disable
  this -- monkeypatch `#accepts?` to return `true` instead (see the top of either `app.rb`). Safe here
  because a facade never renders browser-served HTML or trusts the Host header for anything
  security-sensitive.
- **`set :show_exceptions, :after_handler` plus a generic `error StandardError` backstop handler.**
  Without the backstop, an uncaught exception in *any* route -- including ones you add later without
  thinking about it -- renders Sinatra's detailed exception page (full backtrace, file paths, gem
  versions) to the caller, in every environment. This bit both existing facades for real before the
  handler was added; don't skip it "because my routes all have their own rescue."
- **A `<PREFIX>_`-namespaced env var convention** (`SHALLOT_FACADE_BIND`, `BEACON_PORT`, etc.), not
  generic names like `PORT`/`BIND` -- a facade runs alongside Severance and other services on the same
  host or compose file, and generic names risk colliding.
- **A `VERSION` file**, read at boot and exposed at some info/health endpoint, baked into the Docker
  image as both a build-arg and an `org.opencontainers.image.version` label (see either Dockerfile).

### Directory layout

```
your-facade/
  app.rb              # Sinatra app + routes
  config.ru
  lib/
    severance_client.rb   # the three-call wrapper above
    ...                   # your own translation/mapping logic
  spec/                   # rspec, if you're adding a test suite (recommended -- see security-patch.sh below)
  Gemfile / Gemfile.lock
  Dockerfile              # multi-stage: build stage installs gems, runtime stage is ruby:3.2-alpine,
                           # non-root user baked in, no chown-then-gosu step unless you mount volumes
  docker-compose.yml       # restart: always, security_opt: no-new-privileges, cap_drop: [ALL],
                           # mem_limit/cpus ceilings -- copy either existing one's as a baseline
  env_template
  VERSION
  README.md
```

### Wiring into the security pipeline

Note that you cannot come into this project without going through a security scan!  To add a new facade, read/follow the instructions below, and do a pull-request, or just contact the repo owner for guidance (e.g. submit an Issue).

`Security/security-patch.sh` won't pick up a new facade automatically. Add:

1. A `patch_image <name> ../your-facade ../your-facade/VERSION <YOUR_PREFIX>_VERSION [test_cmd]` call
   alongside the existing two.
2. A `Security/your-facade-docker-compose-template-template.yml` (copy an existing one, swap the
   `image: {TAG}` placeholder name) plus the `cp`/`sed`/`mv` lines that substitute the freshly-pushed
   tag into `../your-facade/docker-compose.yml` and fold it into the same auto-commit block.
3. An entry in `Security/build_register.py`'s `IMAGE_INFO` (exposure tier, control, a note).

See `Security/VULNERABILITY_TRIAGE.md` for the full triage process once findings start showing up.

## History

Both facades moved here from other repos on 2026-09-22 -- `shallot-facade` from
[`Severance`](https://github.com/FAIR-Data-Systems/Severance) (`facades/shallot-facade/`), `beacon-facade`
from [`CARE-Semantic-Model-Version-2`](https://github.com/wilkinsonlab/CARE-Semantic-Model-Version-2)
(`implementation/Beacon2/facade/`, plus its `severance-queries/`.