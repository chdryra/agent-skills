---
description: Audit the codebase for reliability failure modes — unhandled errors, missing timeouts, race conditions, env var gaps — confirm findings with the user, then apply fixes.
---

Perform a reliability audit of the codebase in the current working directory. Identify failure modes, diagnose their root causes, and apply surgical fixes.

---

## Phase 1 — Reconnaissance

Read the entry point(s), all external integration points (HTTP clients, database calls, third-party SDKs), input handling code, and any configuration or startup logic. You are mapping where the system can fail, hang, or produce wrong results under real-world conditions.

Do not start fixing yet.

---

## Phase 2 — Audit

Work through each category below. For every issue you find, record:
- **Where**: file and line number
- **What**: the specific failure mode
- **Root cause**: the precise reason this fails, not just that it might
- **Trigger**: the concrete condition that causes failure (bad input, network timeout, empty result, etc.)
- **Severity**: Critical (data loss or total outage) / High (frequent failure under normal load) / Medium (edge case) / Low (cosmetic or rare)

### Error handling

- **Unhandled async errors**: fire-and-forget async calls where a failure is silently dropped. In Node: `async` functions called without `await`, or `.then()` chains without `.catch()` — these crash the process or fail silently. In Python: unawaited coroutines. In Go: goroutines that don't report errors back to the caller.
- **Swallowed errors**: `catch` blocks that log and continue without propagating or responding with an error status. The caller has no way to know the operation failed.
- **Overly broad catch**: catching `Error` at the top level and returning a generic 500 hides the actual failure class. Distinguish between validation errors (400), auth failures (401/403), not-found (404), and internal errors (500).
- **Missing error handling on external calls**: HTTP requests, database queries, or SDK calls made without any error handling. Ask: what happens if this throws?

### Input validation

- **No validation at trust boundaries**: user-supplied values (request body, query params, path params, headers) used directly without type-checking, range-checking, or sanitisation. Validation belongs at the entry point, not scattered through the business logic.
- **Silent type coercion**: relying on implicit coercion or type widening instead of explicit parsing, so bad input becomes a nonsense value rather than an early error. In JS/TS: `==` instead of `===`, `+` on mixed types, truthy checks on values that could be `0` or `""`. Parse and validate at the boundary in any language.
- **Missing required field checks**: handlers that assume fields are present without checking, leading to cryptic downstream errors when they're absent.

### Configuration and environment

- **Missing environment variable handling**: required config values read without validating they're present, so the process fails late with a cryptic error instead of fast at startup. In Node: `process.env.SOME_VAR` used without a defined check. Apply the same in any language — validate all required config at process start.
- **Hardcoded values that should be configurable**: timeouts, limits, URLs, and retry counts baked into source code. These should be constants at minimum, environment variables where they differ across environments.

### External dependencies

- **No timeout on outbound calls**: HTTP requests or database queries with no timeout set. A slow or unresponsive dependency will hang the request indefinitely, exhausting connection pools. For LLM SDK clients (Anthropic, OpenAI, etc.), a global fetch timeout is not inherited — the timeout must be passed explicitly as a request option (e.g. `AbortSignal.timeout(30_000)` in the second argument to `client.messages.create()`). Without it, a hung API call holds the connection open until the client disconnects.
- **No retry logic for transient failures**: network calls to external APIs with no retry on 5xx or timeout. A single transient failure becomes a user-visible error.
- **No circuit breaking**: repeatedly hammering a failing dependency without back-off, which can cascade into total outage.
- **Assuming external APIs always return the expected shape**: using `response.data.field` without checking if `data` or `field` exist. Validate the response structure before using it.

### State and concurrency

- **Race conditions**: two concurrent operations that read-modify-write shared state without a lock, transaction, or atomic operation. Look for patterns like: fetch a value, compute a new value, write it back — without any isolation.
- **Non-atomic multi-step operations**: sequences of writes that must all succeed or all fail, but are not wrapped in a transaction. A failure mid-sequence leaves data in an inconsistent state.
- **Mutable shared state across requests**: module-level variables that accumulate state across requests in a server context.

### Resource management

- **Unclosed resources**: database connections, file handles, or streams opened but not closed in all code paths (especially error paths). Check that `finally` blocks or `using`/`with` patterns are used where appropriate.
- **Memory leaks**: observers or callbacks registered but never removed, timers never cancelled, caches that grow without bound. In JS: event listeners and `setInterval`/`setTimeout` calls not cleaned up.

---

## Phase 2.5 — Confirm with user

Before fixing anything, present all findings to the user as a list. For each finding include: severity, location (file:line), a one-line description of the issue, and a proposed commit summary in the form `fix(reliability): <what the issue was and what the fix is>`. Then ask two questions:

1. "Which of these would you like me to fix?"
2. "Should I commit each fix as I go, or leave changes unstaged for you to review first?"

Wait for their response before proceeding. Default to leaving changes unstaged if they don't address the commit question.

---

## Phase 3 — Fix

Fix only the issues the user approved, one at a time. For every fix:

1. **Understand before changing.** Re-read the relevant code and confirm your root-cause analysis before touching anything.
2. **Make the minimal change.** Fix only the specific issue. Do not refactor, rename, or improve adjacent code.
3. **Run tests after every change.** The fix must not alter behaviour beyond the issue being addressed. A fix that breaks existing tests is not acceptable.
4. **Trace the full failure path before fixing.** Understand exactly what happens from the point of failure through to the caller and the user. Fix at the right level — not too early (hiding information), not too late (crashing).
5. **Fail fast and loudly at startup for configuration errors.** A missing required env var should throw at process start, not cause a confusing error on the first request.
6. **Commit only if the user said yes in Phase 2.5.** If committing, one commit per issue:
   ```
   fix(reliability): <issue> in <file/function>

   Root cause: <one sentence on the precise cause>
   Impact: <what this caused or allowed>
   Fix: <what was changed and why this is correct>
   ```
   If not committing, leave changes unstaged and summarise what was changed at the end.

---

## Phase 4 — Report

After all fixes are applied, produce a brief findings report. Do not pad it — every finding must include a location and a concrete description. Example:

```
## Reliability Audit Findings

### Fixed
- [CRITICAL] Missing env var check for ANTHROPIC_API_KEY (llm.ts:3) — fails fast at startup
- [HIGH] No error handling on LLM call (llm.ts:8) — added try/catch with typed error response

### Identified but not fixed
- [MEDIUM] No retry on payment API calls — requires retry library integration

### Not found
- No issues found in: resource management, race conditions
```
