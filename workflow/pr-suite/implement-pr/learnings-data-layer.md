# implement-pr — data-layer learnings

Learnings that only apply when a change touches a database, queries, concurrency or access control. Kept out of `SKILL.md` so repos without a data layer don't read them on every run; `SKILL.md` points here when they are relevant. Same rules as the main Learnings section: generic entries only, no private or commercial specifics, at most ~30 entries of 1-3 lines each — merge or drop rather than grow.

- Weigh a foreign key by what it prevents, not what it references. An `ON DELETE RESTRICT` key is often the only thing making a check-then-insert safe, so removing it means every create path must re-read the parent `FOR SHARE` in its own transaction; conversely a table meant to outlive what it records (an audit log, a deletion ledger) needs no cascading key back to it, or the record disappears with the thing it describes.
- Treat a query shape or performance figure the plan hands you as a hypothesis: measure on production-like row counts, compare real query plans rather than reasoning about them, and don't quote a review sub-agent's cost numbers. When a measurement overturns a signed-off decision, amend the plan and tell the user.
