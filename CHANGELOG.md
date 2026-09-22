# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
