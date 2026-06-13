---
description: Explain and describe an unfamiliar codebase — purpose, stack, structure, data flow, and key files
argument-hint: [notion|confluence|<wiki-name>]
allowed-tools: Agent, Read, Glob, Grep, Bash, mcp__notion__API-patch-block-children, mcp__notion__API-post-page, mcp__notion__API-retrieve-a-page, mcp__notion__API-post-search, mcp__notion__API-get-block-children, mcp__notion__API-patch-page
---

Your job is to produce a thorough, readable explanation of the codebase in the current working directory. The explanation is for someone who has never seen this repo before and needs to understand it quickly.

The user invoked this with: $ARGUMENTS

If a wiki name is given as the argument (e.g. `notion`, `confluence`), output to that wiki. Otherwise output directly in the conversation. If the wiki platform is ambiguous, check for available MCP tools (`mcp__notion__*`, Confluence tools, etc.) to detect what's configured, or ask the user.

---

## Phase 1 — Discover (use an Explore subagent)

Spawn an Explore subagent with "very thorough" breadth to answer all of the following. Tell it to ignore `node_modules`, `dist`, `build`, `.git`, `vendor`, `__pycache__`, `*.lock` files, and generated files.

1. What files exist at the root? List them all.
2. What is in the primary manifest file (`package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `pom.xml`, `build.gradle`, etc.)? Extract: name, description, main entry point, key dependencies, scripts.
3. Does a README exist? If so, what does it say the project does?
4. Does a CLAUDE.md exist? If so, what does it say?
5. What is the full directory tree (max 3 levels deep, ignoring the paths above)?
6. What are the main source files — entry points, route definitions, main controllers, top-level modules?
7. Is there a test directory? What framework is used?
8. Are there any CI/CD config files (`.github/workflows`, `Makefile`, `Dockerfile`, etc.)?
9. Are there database migration files (e.g. `*.up.sql`, `*.sql`, `migrations/`, `db/migrate/`)? If so, list their filenames only.

## Phase 2 — Read key files yourself

Based on the Explore subagent's findings, read the following directly (do not spawn another agent):
- The primary manifest file
- The top-level entry point(s)
- Any router/controller/handler files that define the main API or feature surface
- Any database/storage layer files
- Any configuration files that reveal infrastructure decisions
- If migration files exist: read them to extract `CREATE TABLE` statements and understand the schema. For large migration sets (>10 files), read the most recent ones plus any that create core tables.

Read each file fully. Your goal is to trace how a typical request or operation flows through the system end-to-end.

## Phase 2.5 — Build diagrams (wiki output only)

> The following diagram and insertion instructions are for **Notion**. For other wikis, generate the same diagrams as Mermaid source or PNG images and insert them using whatever API or MCP tools your platform provides.

If outputting to Notion, create up to three Mermaid diagrams as images. These are inserted into Notion via the REST API — the MCP tool does not support image blocks.

**Diagram 1: Request / Operation Flow**
Show the path of a typical request through the system: client → middleware → handler → service layer → database. Use `flowchart TD`.

**Diagram 2: Module / Package Dependencies**
Show how the main source packages import each other. Use `flowchart TD`. Read the import statements from the entry point and main packages to build this accurately.

**Diagram 3: Database Schema** (only if there is a relational database)
Show the main entities and their relationships. Use `flowchart TB` or `flowchart LR` — NOT `erDiagram` (flowchart renders with larger, more readable text). For schemas with many tables, split into two focused diagrams (e.g. "Core content model" and "Social/cross-cutting tables") rather than cramming everything into one.

**Encoding and inserting each diagram:**

```python
import base64
mermaid_source = """flowchart TD
    ..."""
encoded = base64.urlsafe_b64encode(mermaid_source.encode()).decode()
url = f"https://mermaid.ink/img/{encoded}?type=png"
print(len(url), url)
```

Critical rules for Mermaid source:
- Use `<br>` for line breaks inside node labels — NEVER `\n` (renders as the literal characters backslash-n in the diagram)
- Always wrap node labels in double quotes when they contain `<br>` tags: `al["activity_log<br>(social feed)"]` — unquoted labels with `<br>` can silently fail to load in Notion
- Always append `?type=png` to the mermaid.ink URL for crisp text rendering
- Keep URLs under 2000 characters (Notion's hard limit). If longer, shorten with: `curl "https://tinyurl.com/api-create.php?url=YOUR_URL"`
- Verify the final URL length before inserting

**Inserting image blocks via REST API:**

The Notion MCP tool only supports `paragraph` and `bulleted_list_item`. For image blocks (and heading blocks), use curl:

```bash
curl -X PATCH "https://api.notion.com/v1/blocks/PAGE_ID/children" \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -H "Notion-Version: 2022-06-28" \
  -d '{
    "children": [
      {
        "type": "image",
        "image": {"type": "external", "external": {"url": "https://mermaid.ink/img/..."}}
      }
    ]
  }'
```

The Notion API token should be available in one of these places — check in order, never hardcode it: a memory file (e.g. `memory/notion_api.md`), a `NOTION_API_KEY` environment variable, or — *Claude Code only* — `~/.claude.json` under `mcpServers.notion.env`. Always add a short italic gray paragraph label *before* each image block so readers know what they're looking at.

When adding multiple blocks in one batch, verify the response — check that `len(results)` matches the number of blocks you sent. Silent failures can occur; if the count is wrong, check which block failed and retry it alone.

## Phase 3 — Produce the explanation

Write the explanation with these sections, in this order. Use plain prose and bullet points — no ASCII art, no box diagrams, no tables.

### 1. What it is
One to three sentences: what this project does, who it's for, what problem it solves.

### 2. Tech stack
Bullet list: language(s), runtime, frameworks, key libraries, database/storage, test framework, build tooling. One line per item.

### 3. Repo structure
For each top-level directory or file that matters, one bullet explaining what lives there and why. Skip anything auto-generated or irrelevant.

### 4. Entry points
Where does execution start? How do you run this thing locally? What are the main commands from the manifest?

### 5. Request / operation flow
Walk through what happens during a typical operation (e.g. an HTTP request, a CLI command, a background job). Name the actual files and functions involved at each step. Write it as numbered steps in plain prose. If a diagram was added (Notion output), reference it here.

### 6. File-by-file breakdown
For each meaningful source file, one bullet: filename — what it does — anything non-obvious about it.

### 7. Things to know
Three to eight bullet points covering: non-obvious design decisions, known rough edges, patterns that are used throughout, anything that would surprise a new reader, anything that looks like a bug or smell worth noting.

---

## Output format rules

- Use plain prose and bullet points throughout. No ASCII art, no box drawings, no tables.
- Be specific — name actual files, functions, and values, not generalities.
- If something is unclear from the code, say so rather than guessing.
- Keep each section tight. A reader should be able to skim headers and dive into the section they need.

### Wiki output rules

Create a new page titled "[repo name] — Codebase Walkthrough" under a relevant parent (e.g. a "Dev" page if one exists, otherwise the workspace root). Add diagrams from Phase 2.5 between section 4 (Entry points) and section 5 (Request flow).

**Notion:** Use `heading_2` blocks via the REST API for section headers (the MCP tool does not support heading blocks). Use `mcp__notion__API-patch-block-children` for `paragraph` and `bulleted_list_item` blocks. Use curl for `heading_2` and `image` blocks. Check the Notion API token is available before starting (memory, `NOTION_API_KEY` env var, or — *Claude Code only* — `~/.claude.json`).

**Confluence:** Create the page via `POST /rest/api/content` with storage-format body. Use headings (`<h2>`) and the Confluence REST API to update. Insert diagrams as attached images or embedded Mermaid macros if the platform supports them.

**Other wikis:** Use whatever page creation and update APIs are available. Prefer Markdown output where the platform accepts it natively.
