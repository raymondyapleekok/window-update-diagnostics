# Design notes (maintainer context, not agent procedure)

Alternatives considered and rejected for this skill's structure:

- **Symptom-indexed decision tree** — rejected: failure signatures change mid-case; the phase pipeline survives them.
- **Manual log collection instead of bundled scripts** — rejected for reproducibility; the cost is script trust, mitigated by review-before-first-run.
- **Shotgun repair sequencing** — rejected by the differential method (SKILL.md Operating principles 6).
- **Keeping procedure text inside SKILL.md** — rejected: restatements drifted from `references/repair-playbook.md`. SKILL.md is the dispatch layer; the references are canonical.
- **Unlimited serial attempts** — rejected: the rollback window (~10 days) needs the per-failure-class attempt budget.

Contribution and release conventions live in README.md (Contributing, Security & privacy, License).
