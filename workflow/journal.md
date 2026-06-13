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
2. **If today's entry exists, append to it — never create a second entry for the same date.** Update the title summary if the day's scope grew.
3. If it doesn't exist, create it with title: `YYYY-MM-DD — <short summary of the day's work>`.
4. Append content using the sections below.

### What to record

Use these sections (only the ones that apply):

- **Done** — work completed, with PR numbers / commit refs / links
- **Decisions** — what was decided and *why*; the rationale is the point
- **Findings** — things discovered (bugs, security issues, doc drift), with `file:line` refs
- **Planned** — tickets created (with links), next steps, sequencing constraints between tickets
- **Post-suggestions / process notes** — reviews, model choices, tooling issues and fixes

Write for a reader with **zero session context**: full sentences, absolute dates, no session-local shorthand. Link tickets, PRs, and related pages. Before finishing, confirm the entry answers: what changed, what was decided and why, what's next.

## Recall mode

When asked what happened previously or why something was decided:

1. List the journal's child entries (sorted chronologically by title).
2. Read the relevant entries. Large results can blow the token limit — extract only the plain text you need.
3. Treat entries as background context reflecting what was true when written; verify file/ticket references still exist before acting on them.

At the start of a session involving non-trivial work, it's worth skimming the most recent entry or two for context.

---

## Notion implementation

The journal lives as a Notion page with dated child pages.

**Finding the journal page:** Search Notion for "Journal" using `API-post-search`. If one result looks right, confirm with the user. If the user has noted the page ID in memory, use that. If none found, ask the user to share the page URL or ID and offer to save it to memory for future sessions.

**Creating entries:** Use `API-post-page` with parent `page_id` = Journal page. Use `API-get-block-children` to list existing entries and check for today's date before creating.

**Formatting constraints:** The `mcp__notion__API-patch-block-children` MCP tool only accepts `paragraph` and `bulleted_list_item` blocks. For headings, call the Notion REST API directly. Find the token in this order — read it programmatically, never echo it: a memory file, a `NOTION_API_KEY` env var, or — *Claude Code only* — `~/.claude.json` under `mcpServers.notion.env`:

```python
import json, urllib.request
# Load token from config
body = {'children': [
    {'object': 'block', 'type': 'heading_2',
     'heading_2': {'rich_text': [{'type': 'text', 'text': {'content': 'Done'}}]}},
]}
req = urllib.request.Request(f'https://api.notion.com/v1/blocks/{PAGE_ID}/children',
                             method='PATCH', headers=headers, data=json.dumps(body).encode())
print(urllib.request.urlopen(req).status)
```

---

## Confluence implementation

The journal lives as a Confluence page with dated child pages under a "Journal" parent.

**Finding the journal page:** Use the Confluence REST API or MCP to search for a page titled "Journal" in the relevant space. Ask the user for the space key and parent page ID if not found in memory.

**Creating entries:** `POST /rest/api/content` with `type: page`, `ancestors: [{id: <journal-page-id>}]`, and the entry title. Use Confluence's storage format (XHTML-based) or the v2 API with Markdown if available.

**Appending to existing entries:** `PUT /rest/api/content/{id}` with the updated body. Always fetch the current version number first — Confluence requires it for updates.

**Auth:** API token via `Authorization: Basic base64(email:token)` or Bearer token. Load from env or config; never hardcode.

---

## Other wikis

For any other wiki (GitHub Wiki, Outline, Coda, etc.):
- Follow the same write/recall structure above.
- Use whatever MCP tools or REST API is available for that platform.
- Ask the user where the journal parent page lives on first use and save it to memory.

## Related

- The `/ticket` skill creates tickets; after creating tickets, log them in the journal under **Planned**.
