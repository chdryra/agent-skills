---
description: Audit the codebase's CI/CD, test coverage, type safety, and linting setup for gaps — confirm findings with the user, then apply fixes.
---

Perform a developer tooling audit of the codebase in the current working directory. Identify gaps in CI/CD, testing, type safety, and code quality infrastructure, diagnose their root causes, and apply surgical fixes.

---

## Phase 1 — Reconnaissance

Read the CI configuration (`.github/workflows/`, `Makefile`, `.circleci/`, `Jenkinsfile`, etc.), the test setup (`jest.config.*`, `vitest.config.*`, `pytest.ini`, etc.), the TypeScript or language config (`tsconfig.json`, `pyproject.toml`, etc.), the linting config (`eslint.config.*`, `.eslintrc.*`, `.flake8`, etc.), and the package manifest (`package.json`, `go.mod`, `pyproject.toml`, etc.).

Do not start fixing yet.

---

## Phase 2 — Audit

Work through each category below. For every issue you find, record:
- **Where**: the specific config file or script
- **What**: the gap or misconfiguration
- **Root cause**: why this is a problem — what failure it allows to slip through
- **Impact**: what class of defect or regression this lets reach production
- **Severity**: High (breaks the safety net entirely) / Medium (weakens it) / Low (hygiene)

### CI pipeline

- **Missing test step**: the pipeline runs build and lint but not the test suite. A green CI build that skips tests provides no regression protection. Verify `pnpm test` / `npm test` / `pytest` / `go test ./...` is present and actually failing the pipeline on failure.
- **Tests running against wrong environment**: tests that hit real external services or a shared database rather than mocks or an isolated test DB. Verify test environment variables are set in CI (e.g. `DB_PATH=:memory:`, `NODE_ENV=test`).
- **No dependency caching**: the pipeline installs dependencies from scratch on every run. Check for `actions/cache` or equivalent. Slow pipelines get skipped.
- **Pipeline never fails on lint errors**: lint step uses `--max-warnings 0` or equivalent, otherwise lint findings are advisory and get ignored.
- **Secrets in CI config**: env vars with real credentials committed in the workflow file rather than stored as CI secrets.
- **Monorepo build ordering**: in a workspace where packages depend on each other, tests for a consumer package will fail on a fresh checkout if the dependency package hasn't been built first (its `dist/` doesn't exist). Check that each package has a `pretest` lifecycle hook (or equivalent) that builds its workspace dependencies before the test runner starts. Don't rely on CI running `build` before `test` as the only safeguard — this breaks for anyone running tests locally without a prior build.

### Test coverage and quality

- **No tests for critical paths**: identify the most important business logic (auth, payments, data mutation) and check whether it has test coverage. A test file existing is not the same as meaningful coverage.
- **Tests only cover the happy path**: check whether edge cases, error paths, and boundary conditions are tested. A test suite that only tests `200 OK` gives false confidence.
- **Mocked tests that diverge from production**: mocks that do not accurately reflect the real dependency's behaviour (e.g. a mock that never throws, when the real service sometimes does). Note these — they are test debt.
- **No integration or end-to-end tests** for a system with external dependencies (database, HTTP APIs). Unit tests alone cannot catch integration bugs.
- **Test setup that leaks state between tests**: shared state not reset between tests causes ordering-dependent failures. Use setup/teardown hooks (`beforeEach`/`afterEach` in Jest/Vitest, `setUp`/`tearDown` in pytest/unittest, `t.Cleanup` in Go) and clean up database records between runs.

### Type safety

> This section is TypeScript-specific. For other typed languages, apply the equivalent: enable the strictest compiler flags available, eliminate wildcard/dynamic types in application code, and enforce type-checking in CI.

- **`strict: false` in tsconfig**: disables `strictNullChecks`, `noImplicitAny`, and related checks. This allows entire classes of null-dereference and type mismatch bugs to compile silently. Enabling strict mode is the highest-value tsconfig change.
- **`skipLibCheck: true` without justification**: skips type-checking of declaration files. Usually fine, but note if it's hiding real errors.
- **`any` types in application code**: grep for `: any` and `as any`. Each is a hole in the type system that hides bugs.
- **No `noUncheckedIndexedAccess`**: array/object index access that returns `T` instead of `T | undefined`, masking off-by-one and missing-key bugs.
- **TypeScript not enforced in CI**: the pipeline runs `tsc` but `noEmit` is not set, meaning the build output may differ from what was type-checked.

### Linting and formatting

- **No linter configured**: no ESLint, Biome, Ruff, golangci-lint, or equivalent. Linters catch real bugs (unused variables, unreachable code, misused APIs) not just style.
- **Linter configured but not run in CI**: the config exists but the pipeline doesn't run it.
- **No formatter** (Prettier, Black, gofmt, etc.) or formatter not enforced in CI. Inconsistent formatting increases cognitive load and causes noisy diffs.
- **Rules too permissive**: linter configured with `warn` instead of `error` for rules that catch real bugs — e.g. `no-unused-vars` / `@typescript-eslint/no-floating-promises` in ESLint, `B` / `RUF` rules in Ruff, `errcheck` in golangci-lint.

### Dependency management

- **No lockfile committed**: without `package-lock.json`, `pnpm-lock.yaml`, `poetry.lock`, or `go.sum`, dependency versions are not reproducible across environments. CI may install different versions than local dev.
- **Outdated dependencies with known vulnerabilities**: run `pnpm audit` / `npm audit` / `safety check`. Note any High or Critical findings.
- **Unpinned dev tool versions**: if the Node/Python/Go version is not pinned in CI (via `.nvmrc`, `.tool-versions`, `engines` field, or the workflow's `node-version`), the build is not reproducible.
- **Cross-tool version incompatibility**: pinning each tool in isolation is not enough — verify that pinned versions are compatible with each other. Example: pnpm 11.5.2 requires Node ≥22.13 (uses `node:sqlite` internally); pinning pnpm to 11.5.2 while leaving Node at 20 breaks CI entirely. When you pin a tool, cross-check its minimum runtime requirement against the pinned runtime version.

---

## Phase 2.5 — Confirm with user

Before fixing anything, present all findings to the user as a list. For each finding include: severity, location (file:line), a one-line description of the issue, and a proposed commit summary in the form `fix(tooling): <what the issue was and what the fix is>`. Then ask two questions:

1. "Which of these would you like me to fix?"
2. "Should I commit each fix as I go, or leave changes unstaged for you to review first?"

Wait for their response before proceeding. Default to leaving changes unstaged if they don't address the commit question.

---

## Phase 3 — Fix

Fix only the issues the user approved, one at a time. For every fix:

1. **Understand before changing.** Re-read the relevant code and confirm your root-cause analysis before touching anything.
2. **Make the minimal change.** Fix only the specific issue. Do not refactor, rename, or improve adjacent code.
3. **Run tests after every change.** The fix must not alter behaviour beyond the issue being addressed. A fix that breaks existing tests is not acceptable.
4. **Understand the full impact before changing config.** A change to `tsconfig.json` (e.g. enabling `strict`) will likely surface new type errors across the codebase. Fix those errors rather than suppressing them — suppression (`// @ts-ignore`, `as any`) defeats the purpose.
5. **Enable strict checks incrementally if necessary.** If enabling `strict: true` surfaces many errors, it is acceptable to fix them in a follow-up commit — but the config change and the first batch of fixes should be in the same PR, not left broken.
6. **Commit only if the user said yes in Phase 2.5.** If committing, one commit per issue:
   ```
   fix(tooling): <issue> in <file/function>

   Root cause: <one sentence on the precise cause>
   Impact: <what this caused or allowed>
   Fix: <what was changed and why this is correct>
   ```
   If not committing, leave changes unstaged and summarise what was changed at the end.

---

## Phase 4 — Report

After all fixes are applied, produce a brief findings report. Do not pad it — every finding must include a location and a concrete description. Example:

```
## Tooling Audit Findings

### Fixed
- [HIGH] Test suite not run in CI (.github/workflows/ci.yml) — added pnpm test step
- [HIGH] TypeScript strict mode disabled (tsconfig.base.json) — enabled strict, fixed resulting errors

### Identified but not fixed
- [MEDIUM] noUncheckedIndexedAccess surfaces 40+ errors — needs dedicated pass

### Not found
- No issues found in: dependency management, formatting
```
