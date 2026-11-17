# Changelog

Notable changes to this skill. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow semantic versioning.

## [2.1.0] - 2026-11-17

Public-release preparation.

### Added
- `LICENSE` (MIT).
- `CHANGELOG.md`.
- `references/closeout-reconciliation.md` — canonical close-out restore semantics, audit method, and verification traps (moved out of SKILL.md).
- `docs/DESIGN-NOTES.md` — design alternatives considered and rejected (maintainer context).
- README: Security & privacy, Contributing, sample-report (redacted), and License sections.
- Comment-based help for `scripts/snapshot-startup-state.ps1` (all scripts now support `Get-Help`).

### Changed
- SKILL.md frontmatter description rewritten to third-person trigger style.
- SKILL.md slimmed to a pure dispatch layer: Phase 7 restore detail and design rationale moved to references/docs.

### Fixed
- SKILL.md cited `repair-playbook.md §Isolation`; the section is `§8` (Spare-disk isolation test).

## [2.0.0]

- Enhanced v2 baseline: two-layer communication standard, attempt-ledger phase, differential-attempt budget, change-ledger/baseline reconciliation, orphan-driver tooling, case studies from a real multi-attempt `0xC1900101-0x40017` investigation.
