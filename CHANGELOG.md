# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.2.0] - 2026-11-06 (both facades)

**Breaking:** both facades refuse to start without their Severance token, and beacon-facade also
without `BEACON_FACADE_AUTH_KEY`. Set them in `.env` before upgrading.

### Security

- **beacon-facade requires `BEACON_FACADE_AUTH_KEY`** and refuses to start without it. When it was unset,
  every caller used to be treated as trusted and got counts instead of yes/no answers -- an
  allow-by-default one forgotten setting away from production. The key is now also compared in
  constant time (it was a plain string comparison).
- Both facades: `rack` 3.2.6 -> 3.2.8, fixing four advisories published by RubySec on 2026-10-30,
  including GHSA-5v64-555j-wjxm (a crafted multipart body is held in memory in full -- enough to crash
  the facade, needing no credentials). None of the four was in GitHub's global advisory database or
  OSV on 2026-11-06, which is why Dependabot never proposed the update.
- Both facades refuse `multipart/form-data` bodies (`415`) before anything parses them, and turn off
  `method_override` (whose middleware reads POST bodies first). Sinatra parses request parameters
  before any route runs, so Rack's multipart parser was reachable by any caller. Neither facade takes
  multipart.
- Both facades now **require** their Severance token (`BEACON_SEVERANCE_AUTH_TOKEN`,
  `SHALLOT_FACADE_SEVERANCE_AUTH_TOKEN`) and refuse to start without it. They used to fall back to
  `YesItsMe`, which Severance External no longer accepts at all.

### Fixed

- **beacon-facade could not start** on the Ruby 3.4 base image (Dependabot bump, PR #2): Ruby 3.4 no
  longer bundles `csv`, which `lib/severance_client.rb` requires. `csv` is now in the Gemfile.
- `Security/security-patch.sh` checks that every freshly built image actually starts before patching
  or pushing it (previously only auto-patched images were boot-tested, so the broken beacon image
  would have been "patched" and pushed). Patch containers now get a throwaway Severance token, which
  both facades need since the change above. beacon-facade's new spec suite runs in the pipeline.

### Added

- `beacon-facade/spec/` -- its first specs (the facade had none).
- `security-patch.sh` pins images by digest in the generated compose files, and records Ruby gem
  findings at every severity (OS findings at CRITICAL/HIGH/UNKNOWN) -- same as Severance's pipeline.

### Credits

- Mark Wilkinson asked for the wider search beyond GitHub's advisory database that turned up the
  `rack` advisories affecting both facades, and decided that beacon-facade must refuse to run without
  its key.

## [0.1.0] - 2026-09-22 (both facades)

### Added

- New repo, consolidating `shallot-facade` (moved from
  [`Severance`](https://github.com/FAIR-Data-Systems/Severance)'s `facades/shallot-facade/`) and
  `beacon-facade` (moved from
  [`CARE-Semantic-Model-Version-2`](https://github.com/wilkinsonlab/CARE-Semantic-Model-Version-2)'s
  `implementation/Beacon2/facade/`, along with its `severance-queries/` binding-contract docs and
  `handoff-beacon-caresm.md`). Neither facade had a real code dependency on the repo it previously
  lived in -- `beacon-facade`'s `require_relative`s only ever reached into its own `lib/` -- so this is
  a directory move, not a refactor. Full pre-move commit history for both is preserved (`git log --
  shallot-facade/` / `git log -- beacon-facade/`); see each repo's own `CHANGELOG.md` for the detailed
  history prior to the move.
- `Security/security-patch.sh`, adapted from Severance's own pipeline but self-contained: both facades
  are patched as plain sibling directories in this one repo now, eliminating the cross-repo
  clone-and-push complexity the old arrangement needed to patch `beacon-facade` from `Severance`
  (including a same-session `docker-compose.yml` tag-auto-push feature that never got to ship in that
  form -- superseded by this repo's simpler, same-repo version). Carries forward
  `auto_patch_ruby_gems.rb`'s three fix strategies (in-constraint bump, constraint-widening bump
  flagged for PR review, phantom-default-gem exact-pin) and `annotate_gem_shadowing.rb`, both copied
  verbatim (already generic).

### Fixed

- `beacon-facade`'s code comments and its own `README.md`/`severance-queries/README.md` referenced
  `../handoff-beacon-caresm.md`, `../../severance-queries/README.md`, and `../facade/lib/...` paths
  that assumed the old `CARE-Semantic-Model-Version-2/implementation/Beacon2/` layout. Updated to the
  new flat `beacon-facade/` layout (`handoff-beacon-caresm.md` and `severance-queries/` now sit
  directly alongside `app.rb`/`lib/`).
