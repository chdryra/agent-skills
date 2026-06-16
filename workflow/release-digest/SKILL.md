---
name: release-digest
description: Turn a range of git commits into readable release notes. Collects commits from a revision range or date window, groups them by conventional-commit type (features, fixes, etc.), optionally rewrites terse commit subjects into plain-English prose, and renders them as a self-contained HTML page, a Markdown file, or a Notion page. Based on git history only — no issue tracker, deploy pipeline, or product taxonomy required. Use when asked for release notes, a changelog, or a release digest.
argument-hint: [--range v1.0.0..HEAD | --from YYYY-MM-DD --until YYYY-MM-DD] [--notion | --markdown] [--title "..."]
allowed-tools: Bash, Read, Write, Edit
---

# release-digest

Turn a range of git commits into a readable set of release notes. The pipeline is **git history only** — no issue tracker, deploy pipeline, or product taxonomy. Output is HTML by default, with Markdown and Notion options.

Two bundled stdlib-only scripts do the deterministic work; the model sits in the middle to humanise terse commit subjects:

```
collect.py  ──▶  (optional: humanise headlines)  ──▶  render.py  ──▶  HTML / Markdown / Notion
  git log            the model rewrites subjects        grouping
```

**Usage:**
```
/release-digest                                   # since the last tag (or last 30 days)
/release-digest --range v1.3.0..HEAD
/release-digest --from 2026-05-26 --until 2026-06-02
/release-digest --markdown                        # Markdown instead of HTML
/release-digest --notion                          # publish to Notion as well
/release-digest --title "Release 1.4.0"
```

**Prerequisites:**
- A git repository (run from inside it).
- For `--notion`: Notion MCP tools (`mcp__notion__*`) or a `NOTION_API_KEY`.

---

## Step 1 — Parse arguments

From `$ARGUMENTS`, read:
- `--range <rev-range>` — any range `git log` accepts (`v1.0.0..HEAD`, `abc123..def456`).
- `--from` / `--until` (YYYY-MM-DD) — a date window instead of a range. `--until` is inclusive of the whole day.
- `--markdown` — render Markdown instead of HTML.
- `--notion` — also publish the notes to Notion (see Step 5).
- `--title "..."` — heading for the notes. Default: `Release notes`.
- `--no-merges` — exclude merge commits (recommended for squash-merge repos where the merge commit duplicates the PR).

If neither `--range` nor `--from/--until` is given, `collect.py` defaults to **the most recent tag → HEAD**, falling back to the last 30 days if the repo has no tags.

Derive a sensible `--period` string for the notes header (e.g. `v1.3.0 → HEAD` or `26 May – 2 Jun 2026`).

---

## Step 2 — Collect commits

Run the bundled `collect.py` (stdlib only, no pip install):

```bash
SKILL_DIR="<dir this SKILL.md lives in>"   # e.g. ~/.claude/skills/release-digest
python3 "$SKILL_DIR/collect.py" --range "$RANGE" --no-merges > /tmp/release-commits.json
# or: python3 "$SKILL_DIR/collect.py" --from "$FROM" --until "$UNTIL" --no-merges > /tmp/release-commits.json
```

Each commit is parsed for a conventional-commit prefix (`feat`, `fix(scope)`, `feat!`, etc.), a trailing `(#123)` PR reference, and `BREAKING CHANGE` markers. Plain subjects with no prefix are kept and fall under "Other changes".

Read the JSON. If it's empty, tell the user there are no commits in the range and stop.

---

## Step 3 — Humanise the headlines (recommended)

Commit subjects are written for developers; release notes are read by users. For each commit, fill the empty `headline` field with one plain-English sentence describing the change from the reader's perspective:

- Drop jargon, internal module names, and ticket/PR codes (those are kept separately as a reference suffix).
- Turn imperatives into outcomes: `fix(api): handle empty payload` → "The API no longer errors when sent an empty request body."
- Skip noise: for pure `chore`/`ci`/`build`/`style`/dependency-bump commits, a light touch is fine — or leave the `headline` blank and let `render.py` fall back to the cleaned subject.
- **Do not invent detail** not present in the commit. If a subject is too terse to interpret, leave the `headline` blank rather than guessing.

This step is optional — if you skip it, `render.py` falls back to each commit's parsed description, which still produces usable (if terse) notes. For large ranges, edit the JSON in batches.

Write the updated array back to `/tmp/release-commits.json`.

> **Keep it generic.** These notes may be published. Do not add anything not in the commit history — no customer names, internal project codenames, or unreleased plans.

---

## Step 4 — Render

```bash
# HTML (default)
python3 "$SKILL_DIR/render.py" --title "$TITLE" --period "$PERIOD" \
  < /tmp/release-commits.json > /tmp/release-notes.html

# Markdown (--markdown)
python3 "$SKILL_DIR/render.py" --markdown --title "$TITLE" --period "$PERIOD" \
  < /tmp/release-commits.json > /tmp/release-notes.md
```

Commits are grouped under friendly headings (✨ New features, 🐛 Fixes, ⚡ Performance, …), with breaking changes surfaced in their own section at the top. The HTML is self-contained (inline CSS, no JS, no external requests).

Copy the output somewhere durable and report the path:
```bash
cp /tmp/release-notes.html ~/Documents/release-notes.html
```

---

## Step 5 — Publish to Notion (`--notion` only)

If `--notion` was passed, also publish the notes as a Notion page.

**Detect Notion** the same way the other skills do: Notion MCP tools (`mcp__notion__*`) available? If not, check for a `NOTION_API_KEY`; otherwise tell the user Notion is unavailable and stop after Step 4.

1. Render Markdown (Step 4 `--markdown`) — it maps cleanly onto Notion blocks.
2. Ask the user (or check memory) for the parent page under which the release notes should live. Search with `API-post-search` for an existing "Release notes" page if unsure.
3. Create the page with `API-post-page` (title = `$TITLE`, parent = that page).
4. Add the body. `mcp__notion__API-patch-block-children` accepts `paragraph` and `bulleted_list_item` blocks — map each `## heading` to a `heading_2` and each `- bullet` to a `bulleted_list_item`. For `heading_2` blocks (which the MCP tool doesn't accept), call the Notion REST API directly. Read the token in this order — programmatically, **never echo it**: a memory file, a `NOTION_API_KEY` env var, or — *Claude Code only* — `~/.claude.json` under `mcpServers.notion.env`.

```python
import json, urllib.request
# load token from config (never print it)
body = {'children': [
    {'object': 'block', 'type': 'heading_2',
     'heading_2': {'rich_text': [{'type': 'text', 'text': {'content': 'New features'}}]}},
]}
req = urllib.request.Request(f'https://api.notion.com/v1/blocks/{PAGE_ID}/children',
                             method='PATCH', headers=headers, data=json.dumps(body).encode())
print(urllib.request.urlopen(req).status)
```

Report the Notion page URL.

---

## Step 6 — Summarise

Tell the user:
- The output path(s) / Notion URL.
- Total commit count and the range/window covered.
- A count per section (features / fixes / etc.) and any breaking changes.
- Any commits you left un-humanised because they were too terse to interpret.

Open the HTML automatically if produced:
```bash
open ~/Documents/release-notes.html
```

---

## Notes

- Both scripts are stdlib-only — no `pip install`, no network. `collect.py` shells out to `git log`; `render.py` is pure string templating.
- Conventional commits make the grouping sharper, but the skill degrades gracefully on plain subjects (everything lands in "Other changes").
- For a squash-merge repo, `--no-merges` plus the `(#N)` PR reference gives one clean line per PR.
- Re-run with a different `--range` to regenerate; the scripts hold no state.
