---
description: Audit the codebase for security vulnerabilities — injection, auth bypass, weak crypto, CORS misconfiguration — confirm findings with the user, then apply fixes.
---

Perform a security audit of the codebase in the current working directory. Identify vulnerabilities, diagnose their root causes, and apply surgical fixes.

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

### Authentication and authorisation

- Hardcoded credentials or API keys in source files. Check `.env` files committed to the repo, string literals matching key patterns (`sk-`, `Bearer `, `password =`).
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

## Phase 2.5 — Confirm with user

Before fixing anything, present all findings to the user as a list. For each finding include: severity, location (file:line), a one-line description of the issue, and a proposed commit summary in the form `fix(security): <what the issue was and what the fix is>`. Then ask two questions:

1. "Which of these would you like me to fix?"
2. "Should I commit each fix as I go, or leave changes unstaged for you to review first?"

Wait for their response before proceeding. Default to leaving changes unstaged if they don't address the commit question.

---

## Phase 3 — Fix

Fix only the issues the user approved, one at a time. For every fix:

1. **Understand before changing.** Re-read the relevant code and confirm your root-cause analysis before touching anything.
2. **Make the minimal change.** Fix only the specific issue. Do not refactor, rename, or improve adjacent code.
3. **Run tests after every change.** The fix must not alter behaviour beyond the issue being addressed. A fix that breaks existing tests is not acceptable.
4. **Consider migration.** Security fixes (especially credential rotation or schema changes) may need a migration path. If a safe incremental approach exists, prefer it over a single breaking change.
5. **Commit only if the user said yes in Phase 2.5.** If committing, one commit per issue:
   ```
   fix(security): <issue> in <file/function>

   Root cause: <one sentence on the precise cause>
   Impact: <what this caused or allowed>
   Fix: <what was changed and why this is correct>
   ```
   If not committing, leave changes unstaged and summarise what was changed at the end.

---

## Phase 4 — Report

After all fixes are applied, produce a brief findings report. Do not pad it — every finding must include a location and a concrete description. Example:

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
