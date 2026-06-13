---
description: Audit the codebase for performance bottlenecks — N+1 queries, missing indexes, unbounded result sets, sequential async ops — confirm findings with the user, then apply fixes.
---

Perform a performance audit of the codebase in the current working directory. Identify bottlenecks, diagnose their root causes, and apply surgical fixes.

---

## Phase 1 — Reconnaissance

Read the entry point(s), data access layer, any background jobs or batch processors, and any route handlers that deal with lists or paginated data. Understand the data model and the expected scale: how many rows, how many concurrent users, how frequently each operation runs.

Do not start fixing yet.

---

## Phase 2 — Audit

Work through each category below. For every issue you find, record:
- **Where**: file and line number
- **What**: the specific performance anti-pattern
- **Root cause**: why this code is slow, not just that it is
- **Impact**: how this degrades as data or load grows (be specific — O(n) query inside O(n) loop = O(n²) database round-trips)
- **Severity**: High / Medium / Low based on expected call frequency and data volume

### Database and query efficiency

- **N+1 queries**: a loop that issues one query per iteration. Look for `for`/`forEach`/`map` blocks that contain `db.query`, `findOne`, or ORM fetch calls. The fix is a single query with a `WHERE id IN (...)` clause or a JOIN, not sequential fetches.
- **Full table scans**: `SELECT * FROM table` without a `WHERE` clause, followed by in-process filtering. The filter belongs in SQL.
- **Missing indexes**: columns used in `WHERE`, `ORDER BY`, or `JOIN ON` clauses that have no index. Check migration files and schema definitions.
- **`SELECT *`**: fetching all columns when only a subset are used. Name the columns you need.
- **Unbounded result sets**: queries with no `LIMIT`. At scale these will return millions of rows.
- **Blocking I/O on an async runtime**: using a synchronous/blocking API where the runtime expects non-blocking calls. In Node: `better-sqlite3` sync calls on the event loop. In Python: blocking I/O inside asyncio coroutines. In Go: blocking network calls that should run in a goroutine pool.

### Concurrency and parallelism

- **Sequential async operations that could be parallel**: running independent async operations one at a time when they could run concurrently. In JS: a `for` loop with `await` inside — replace with `Promise.all()`. In Python: sequential `await` calls — use `asyncio.gather()`. In Go: blocking on each goroutine — fan out with a WaitGroup.
- **Unnecessary serialisation**: batch operations processed one-at-a-time when the downstream service supports bulk APIs.
- **Missing connection pooling**: creating a new database or HTTP connection per request rather than reusing a pool.

### Caching

- **Repeated identical queries**: the same query issued on every request with the same parameters. Look for calls inside request handlers that return data that changes infrequently. Consider in-memory caching (with TTL) or a cache table/layer.
- **Cache invalidation absent**: a cache exists but is never invalidated when the underlying data changes, leading to stale reads.
- **Missing HTTP caching headers**: `GET` endpoints returning data that is safe to cache but not setting `Cache-Control`, `ETag`, or `Last-Modified`.

### Payload and serialisation

- **Over-fetching**: returning entire objects (including large fields like raw text, blobs, or nested relations) when the caller only needs a subset.
- **Missing pagination**: list endpoints that return all records. Any endpoint that could return more than ~100 items needs `limit`/`offset` or cursor-based pagination.
- **Serialising large objects on the hot path**: JSON stringifying or parsing large payloads synchronously on each request.

### Memory

- **Unbounded in-memory accumulation**: arrays or maps that grow without a cap (e.g. accumulating all results before processing, no streaming).
- **Retaining references that prevent GC**: event listeners, timers, or closures that hold references to large objects beyond their useful life.

---

## Phase 2.5 — Confirm with user

Before fixing anything, present all findings to the user as a list. For each finding include: severity, location (file:line), a one-line description of the issue, and a proposed commit summary in the form `fix(perf): <what the issue was and what the fix is>`. Then ask two questions:

1. "Which of these would you like me to fix?"
2. "Should I commit each fix as I go, or leave changes unstaged for you to review first?"

Wait for their response before proceeding. Default to leaving changes unstaged if they don't address the commit question.

---

## Phase 3 — Fix

Fix only the issues the user approved, one at a time. For every fix:

1. **Understand before changing.** Re-read the relevant code and confirm your root-cause analysis before touching anything.
2. **Make the minimal change.** Fix only the specific issue. Do not refactor, rename, or improve adjacent code.
3. **Run tests after every change.** The fix must not alter behaviour beyond the issue being addressed. A fix that breaks existing tests is not acceptable.
4. **Preserve behaviour.** The fix must produce identical results — just faster. If batching queries changes error semantics (e.g. partial failure), handle that explicitly.
5. **Commit only if the user said yes in Phase 2.5.** If committing, one commit per issue:
   ```
   fix(perf): <issue> in <file/function>

   Root cause: <one sentence on the precise cause>
   Impact: <what this caused or allowed>
   Fix: <what was changed and why this is correct>
   ```
   If not committing, leave changes unstaged and summarise what was changed at the end.

---

## Phase 4 — Report

After all fixes are applied, produce a brief findings report. Do not pad it — every finding must include a location and a concrete description. Example:

```
## Performance Audit Findings

### Fixed
- [HIGH] Full table scan + JS filter in getAllSummariesForUser (db.ts:48) — added WHERE clause
- [MEDIUM] Sequential summarizeBatch (llm.ts:28) — replaced with Promise.all

### Identified but not fixed
- [MEDIUM] Missing index on events.user_id — requires schema migration

### Not found
- No issues found in: caching, payload size, memory
```
