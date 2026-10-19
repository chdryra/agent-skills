---
description: Audit the codebase for security vulnerabilities — injection, auth bypass, weak crypto, CORS misconfiguration — confirm findings with the user, then apply fixes.
---

Perform a security audit of the codebase in the current working directory. Identify vulnerabilities, diagnose their root causes, and apply surgical fixes.

Read `~/.claude/commands/_audit-protocol.md` for the shared protocol governing Phase 0 (scope: the project rulebook, what changed since the last audit, every finding cites a rule), Phase 2.5 (confirm with user), Phase 3 (fix rules + commit format), and Phase 4 (report template). Run Phase 0 before Phase 1 below, and apply the other phases exactly as written there.

---

## Phase 1 — Reconnaissance

Read the entry point(s), routing layer, database layer, auth middleware, and any file that handles user input or external data. You are looking for where untrusted data enters the system and how it flows through it.

Do not start fixing yet.

---

## Phase 2 — Audit

Work through each category below. For every issue you find, record:
- **Where**: file and line number
- **What**: the specific vulnerability class
- **Root cause**: why this code is vulnerable, not just that it is
- **Impact**: what an attacker could do, and how easily
- **Severity**: Critical / High / Medium / Low

### Injection

- SQL injection: search for query construction using string interpolation or concatenation (`` `SELECT... ${var}` ``, `"..." + var`). Parameterized queries (`?` placeholders or ORM equivalents) are the only safe pattern.
- Command injection: look for OS process execution or dynamic eval calls that incorporate user input — `child_process`/`exec`/`spawn` in Node, `subprocess`/`os.system` in Python, `exec.Command` in Go.
- NoSQL injection: in MongoDB/similar, look for unsanitized objects passed directly to query operators.
- Prompt injection: in LLM-integrated code, look for user-supplied text interpolated directly into prompt strings (e.g. `` `Summarize: ${userText}` ``). An attacker can embed instructions that override system prompts, exfiltrate data, or manipulate the model's output. User input should be treated as data, not instructions — pass it in a clearly delimited user message rather than constructing prompt strings via concatenation. Also check whether LLM output is trusted for downstream operations (rendered as HTML, used in a SQL query, passed to a shell) — model output is untrusted data.

### Authentication and authorisation

- Hardcoded credentials or API keys in source files. Check string literals matching key patterns (`sk-`, `Bearer `, `password =`).
- `.env` not in `.gitignore`: distinct from hardcoded keys — the source may correctly use `process.env`, but if `.env` is not gitignored, real credentials placed there will be committed. Check `.gitignore` explicitly. Also verify a `.env.example` exists with placeholder values so developers know what variables are required without needing to share the actual secrets.
- Missing or bypassable auth checks on routes — trace each route handler and verify that protected routes actually enforce authentication before proceeding.
- Privilege escalation: routes that accept a user ID from the request body/params and use it without verifying it matches the authenticated session.
- JWT or session issues: weak secrets, no expiry, algorithm confusion (`"alg": "none"`).

### Input validation

- Missing validation on all inputs that cross a trust boundary: HTTP request body, query params, path params, file uploads, webhook payloads.
- Type coercion issues — values that should be numbers, UUIDs, or enums being used as strings without validation.

### Cryptography

- Weak hashing: MD5 or SHA-1 used for passwords or security-sensitive tokens. Passwords must use bcrypt, argon2, or scrypt.
- Non-cryptographic randomness used for tokens, IDs, or anything security-sensitive — use the platform's CSPRNG. In JS: avoid `Math.random()`, use `crypto.randomUUID()` or `crypto.randomBytes()`. In Python: use the `secrets` module. In Go: use `crypto/rand`.
- Sensitive data stored or logged in plaintext.

### CORS and transport

- `Access-Control-Allow-Origin: *` combined with `Access-Control-Allow-Credentials: true` — this combination is invalid per the spec and allows credential theft.
- CORS origins reflected from the request `Origin` header without a whitelist.
- Sensitive endpoints reachable over HTTP rather than requiring HTTPS.

### Dependency and supply chain

- Run `npm audit` / `pnpm audit` / `pip audit` / `go list -m -u`. Note any Critical or High CVEs.
- Look for unpinned dependency versions (`*`, `latest`, overly broad ranges) in security-sensitive libraries.

---

## Phase 3 addendum — Security-specific fix rule

In addition to the shared Phase 3 rules: **consider migration.** Security fixes (especially credential rotation or schema changes) may need a migration path. If a safe incremental approach exists, prefer it over a single breaking change.

---

## Phase 4 example

```
## Security Audit Findings

### Fixed
- [CRITICAL] SQL injection in getUserByEmail (db.ts:40) — parameterized query
- [HIGH] Hardcoded API key in llm.ts:3 — moved to process.env

### Identified but not fixed
- [MEDIUM] Weak session secret — requires coordinated secret rotation across environments

### Not found
- No issues found in: XSS, CSRF, command injection
```
