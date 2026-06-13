---
description: Write or read a session handoff file in .context/ — preserves in-session context across agent restarts
argument-hint: [write|read [title]]
allowed-tools: Read, Write, Glob, Grep, Bash
---

Manage session handoff files in the `.context/` directory of the current workspace.

The user invoked this with: $ARGUMENTS

Derive the **workspace key** used in the filename by checking these in order:
1. `CONDUCTOR_WORKSPACE_NAME` env var (Conductor)
2. `VSCODE_WORKSPACE_FOLDER` env var, basename only (Cursor / VS Code)
3. Current git branch name: `git rev-parse --abbrev-ref HEAD`
4. Current directory basename as a last resort

---

## If argument is "write" (or no argument given)

1. Synthesise the current session into a handoff file at `.context/handoff-<workspace-key>.md`. Overwrite any existing file.

2. Before writing, ask yourself: what would a short, memorable human title be for this session's work? Something like "GykDb category events + focus spec" or "auth refactor + rate limiting". 2-6 words. This goes at the top of the file as the human-readable title.

3. The file must be self-contained — a cold agent with no prior context must be able to pick up from it alone.

   Structure:
   ```
   # <human-readable title>
   <!-- workspace: <workspace-key> | date: <date> -->

   ## What we were doing
   One paragraph. The task or feature in progress and why it matters.

   ## What was done this session
   Bullet list. Concrete things completed, decided, or ruled out. Include PR numbers or commit refs if relevant.

   ## Current state
   What is true RIGHT NOW — what's working, what's broken, what's partially done. Be specific about file paths and line numbers.

   ## What's next
   Ordered list. Immediate next action first. Include:
   - Exact file paths to edit
   - Function or type names to add/change
   - Any migration or codegen steps needed
   - Test coverage expected

   ## Open questions / blockers
   Anything unresolved that the next agent should investigate or ask the user about.

   ## Key file locations
   Only files non-obvious or central to the current work. Skip anything already in CLAUDE.md.
   ```

4. After writing, confirm to the user: "Saved: **<human-readable title>** (`handoff-<workspace-key>.md`)"

---

## If argument is "read" with no further text

Search for handoff files in these locations (skip any that don't exist):
1. `.context/handoff-*.md` in the current working directory
2. `~/conductor/archived-contexts/**/handoff-*.md` (Conductor only)

For each file found, show:
- The human-readable title (first line of the file)
- The workspace key (from the filename)
- The date (from the comment on line 2)
- The source location

Present as a numbered list and ask the user which one to load, or tell them they can type `/handoff read <partial title>` to load one directly.

---

## If argument is "read <partial title or workspace key>"

Search for matching handoff files in these locations (skip any that don't exist):
1. `.context/handoff-*.md` in the current working directory
2. `~/conductor/archived-contexts/**/handoff-*.md` (Conductor only)

Find the file whose human-readable title or workspace key best matches the given text (case-insensitive, partial match is fine). If exactly one match, load it. If multiple, list them and ask. If none, say so.

Once a file is identified, read it and give the user a short summary (3-5 bullet points) of what the previous session covered and what the immediate next action is. Do not re-explain things at length — just orient and offer to continue.
