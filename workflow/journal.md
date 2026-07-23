---
description: Work journal — log daily activity, decisions, and findings; recall what happened in past sessions. Supports Notion, Confluence, or any hierarchical wiki.
---

# Work Journal

The journal is durable, human-readable memory of project work — for the user and for future agents picking up cold. Two modes: **write** (log today's activity/decisions) and **recall** (read past entries to recover context).

## Detecting your wiki

Check in this order:
1. Are Notion MCP tools available (`mcp__notion__*`)? → Use Notion.
2. Is a `CONFLUENCE_URL` env var set, or are Confluence MCP tools available? → Use Confluence.
3. Check memory for a previously noted wiki preference.
4. Ask the user which wiki to use and where the journal lives.

## Write mode

1. Find today's entry: look for a child page / section whose title starts with today's date (`YYYY-MM-DD`).
2. **If today's entry exists, update it — never create a second entry for the same date.** Refresh existing sections in place rather than appending duplicates. Update the title summary if the day's scope grew.
3. If it doesn't exist, create it with title: `YYYY-MM-DD — <short summary of the day's work>`.

### Ticket Summary section (if an issue tracker is connected)

Open the entry with a **Ticket Summary** heading containing three groups, populated from real-time tracker status (not from memory of the session):

- **Completed this session:** — tickets finished (PR merged or status → Done). Linked bullets. If none, `—`.
- **In progress at end of session:** — tickets started but not finished (branch cut or PR open, not merged). Tickets created straight into the backlog do **not** belong here. If none, `—`.
- **Tickets created:** — new tickets opened this session, started or not. If none, `—`.

### What to record — the substance bar

The reader is someone months from now deciding what happened and why. Every line must earn its place by telling them something they couldn't guess. Use these sections, only the ones that apply:

- **Done** — outcomes shipped, with PR numbers / commit refs / links.
- **Decisions** — what was decided and *why*; the rationale is the point.
- **Findings** — things discovered (bugs, security issues, doc drift), with `file:line` refs.
- **Planned** — tickets created (with links), next steps, sequencing constraints between tickets.
- **Process notes** — skill/tooling improvements, review-cycle lessons, model choices.

**When a ticket is completed this session, the entry must describe what the ticket delivered as a whole** — what a user or the system can now do that it couldn't before — even if most of the implementation happened in an earlier session. Check the last entry or two: if no previous entry covered the implementation, summarise it here from the ticket and PR. "Addressed review comments and merged PR #NN" is a footnote, not a record of the work.

Do **not** record routine mechanics, unless one had unusual consequences worth explaining:

- updating a branch with main, pushing, rebasing
- build/format/test checks passing (fold "tests pass" into the outcome line if worth saying at all)
- worktree/branch/scratch-file housekeeping
- replying to reviewers, PR ceremony

A short entry beats a padded one. If a session produced little of substance, two or three lines is a perfectly good entry.

### Writing style

Plain, everyday English for a reader with zero session context — including a non-technical one. Full sentences, absolute dates, no session-local shorthand. Lead each bullet with the outcome, then the supporting detail. Gloss any unavoidable technical term the first time it appears (e.g. "a worktree — a separate working copy of the repo"). Link tickets, PRs, and related pages.

Plain English is not a licence to narrate: apply the substance bar first, then explain what survives it simply. Before finishing, confirm the entry answers: what changed, what was decided and why, what's next.

## Recall mode

When asked what happened previously or why something was decided:

1. List the journal's child entries (sorted chronologically by title).
2. Read the relevant entries. Extract only the plain text you need.
3. Treat entries as background context reflecting what was true when written; verify file/ticket references still exist before acting on them.

At the start of a session involving non-trivial work, it's worth skimming the most recent entry or two for context.

---

## Notion implementation

The journal lives as a Notion page with dated child pages.

**Finding the journal page:** Search Notion for "Journal" using `API-post-search`. If one result looks right, confirm with the user. If the user has noted the page ID in memory, use that. If none found, ask the user to share the page URL or ID and offer to save it to memory for future sessions.

**Use the markdown tools only.** They handle headings, bold, and links natively, and a whole page is one call each way:

- `API-retrieve-page-markdown` — read a page as compact markdown. On the Journal parent page, this returns the list of dated entries (titles + URLs) in one small call.
- `API-update-page-markdown` — edit a page. `replace_content` rewrites the whole page; `update_content` applies exact find-and-replace edits (copy `old_str` verbatim from a fresh `API-retrieve-page-markdown` read).
- `API-post-page` — create the day's page with its title only, then write the body with one `replace_content` call.
- `API-patch-page` — update a page title.

Do **not** use the block-level tools (`API-get-block-children`, `API-patch-block-children`, per-block deletes) or the raw Notion REST API for journal work. The delete-every-block-and-rebuild pattern they force is obsolete; it takes dozens of calls to do what `update_content` does in one.

---

## Confluence implementation

The journal lives as a Confluence page with dated child pages under a "Journal" parent.

**Finding the journal page:** Use the Confluence REST API or MCP to search for a page titled "Journal" in the relevant space. Ask the user for the space key and parent page ID if not found in memory.

**Creating entries:** `POST /rest/api/content` with `type: page`, `ancestors: [{id: <journal-page-id>}]`, and the entry title. Use Confluence's storage format (XHTML-based) or the v2 API with Markdown if available.

**Updating existing entries:** `PUT /rest/api/content/{id}` with the updated body. Always fetch the current version number first — Confluence requires it for updates.

**Auth:** API token via `Authorization: Basic base64(email:token)` or Bearer token. Load from env or config; never hardcode.

---

## Other wikis

For any other wiki (GitHub Wiki, Outline, Coda, etc.):
- Follow the same write/recall structure above.
- Use whatever MCP tools or REST API is available for that platform.
- Ask the user where the journal parent page lives on first use and save it to memory.

## Related

- The `/ticket` skill creates tickets; after creating tickets, log them in the journal under **Planned**.
