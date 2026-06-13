#!/usr/bin/env python3
"""Render collected commits as readable release notes.

Input: the JSON array produced by collect.py (optionally with each commit's
`headline` field filled in with human-readable prose by the skill). Commits
are grouped by conventional-commit type under friendly headings; anything
without a recognised type falls under "Other changes". Breaking changes are
surfaced in their own section at the top.

Usage:
    python3 render.py < commits.json > notes.html
    python3 render.py --markdown < commits.json > notes.md
    python3 render.py --title "Release 1.4.0" --period "May 2026" < commits.json > notes.html

Output is self-contained HTML (inline CSS, no JS, no external deps) or
GitHub-flavoured Markdown. The Markdown form is also what you feed to a
Notion publish step (see the skill).
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from collections import OrderedDict

# Conventional-commit type -> (display heading, sort order). Unlisted types
# fall through to "Other changes". Keep features and fixes first.
SECTIONS = OrderedDict(
    [
        ("feat", "✨ New features"),
        ("fix", "🐛 Fixes"),
        ("perf", "⚡ Performance"),
        ("refactor", "♻️ Refactoring"),
        ("docs", "📝 Documentation"),
        ("test", "✅ Tests"),
        ("build", "🔧 Build & dependencies"),
        ("ci", "🔧 Build & dependencies"),
        ("chore", "🧹 Maintenance"),
        ("style", "🧹 Maintenance"),
    ]
)
OTHER_HEADING = "Other changes"
BREAKING_HEADING = "⚠️ Breaking changes"


def _e(text: str) -> str:
    return html.escape(str(text))


def _line_text(commit: dict) -> str:
    """Preferred human text for a commit: filled headline, else description."""
    headline = (commit.get("headline") or "").strip()
    if headline:
        return headline
    desc = (commit.get("description") or "").strip()
    if desc:
        return desc
    return (commit.get("subject") or "").strip()


def _suffix(commit: dict) -> str:
    """Trailing reference: scope + PR/hash, as plain text."""
    bits = []
    scope = (commit.get("scope") or "").strip()
    if scope:
        bits.append(scope)
    pr = (commit.get("pr_number") or "").strip()
    if pr:
        bits.append(f"#{pr}")
    elif commit.get("hash"):
        bits.append(commit["hash"])
    return " · ".join(bits)


def _group(commits: list[dict]) -> "OrderedDict[str, list[dict]]":
    groups: "OrderedDict[str, list[dict]]" = OrderedDict()
    # Seed in display order so empty sections are skipped but order is stable.
    seen_headings: list[str] = []
    for heading in list(SECTIONS.values()) + [OTHER_HEADING]:
        if heading not in seen_headings:
            seen_headings.append(heading)
            groups[heading] = []
    for c in commits:
        heading = SECTIONS.get((c.get("type") or "").lower(), OTHER_HEADING)
        groups[heading].append(c)
    return OrderedDict((h, items) for h, items in groups.items() if items)


def render_markdown(commits: list[dict], title: str, period: str) -> str:
    lines = [f"# {title}"]
    if period:
        lines.append(f"_{period}_")
    lines.append("")

    breaking = [c for c in commits if c.get("breaking")]
    if breaking:
        lines.append(f"## {BREAKING_HEADING}")
        lines.append("")
        for c in breaking:
            suffix = _suffix(c)
            tail = f" ({suffix})" if suffix else ""
            lines.append(f"- {_line_text(c)}{tail}")
        lines.append("")

    for heading, items in _group(commits).items():
        lines.append(f"## {heading}")
        lines.append("")
        for c in items:
            suffix = _suffix(c)
            tail = f" ({suffix})" if suffix else ""
            lines.append(f"- {_line_text(c)}{tail}")
        lines.append("")

    lines.append(f"---")
    lines.append(f"_{len(commits)} change{'s' if len(commits) != 1 else ''} in total._")
    return "\n".join(lines)


def _li(commit: dict) -> str:
    suffix = _suffix(commit)
    tail = (
        f' <span style="color:#888;font-size:0.85em">({_e(suffix)})</span>'
        if suffix
        else ""
    )
    return f"<li>{_e(_line_text(commit))}{tail}</li>"


def render_html(commits: list[dict], title: str, period: str) -> str:
    parts = [
        "<!doctype html>\n<html><head><meta charset='utf-8'>",
        "<style>",
        "body{font-family:-apple-system,Segoe UI,sans-serif;"
        "max-width:780px;margin:2em auto;padding:0 1em;line-height:1.55;color:#222}",
        "h1{font-size:1.6em;margin-bottom:0.1em}",
        "h2{font-size:1.15em;margin-top:1.6em;padding-bottom:0.3em;"
        "border-bottom:1px solid #e0e0e0}",
        ".period{color:#666;font-size:0.95em;margin-top:0}",
        ".breaking h2{border-color:#f44336;color:#c62828}",
        "ul{padding-left:1.3em}li{margin:0.25em 0}",
        ".footer{margin-top:2em;color:#888;font-size:0.85em;"
        "border-top:1px solid #e0e0e0;padding-top:0.8em}",
        "</style></head><body>",
        f"<h1>{_e(title)}</h1>",
    ]
    if period:
        parts.append(f'<p class="period">{_e(period)}</p>')

    breaking = [c for c in commits if c.get("breaking")]
    if breaking:
        parts.append('<div class="breaking">')
        parts.append(f"<h2>{_e(BREAKING_HEADING)}</h2><ul>")
        parts.extend(_li(c) for c in breaking)
        parts.append("</ul></div>")

    for heading, items in _group(commits).items():
        parts.append(f"<h2>{_e(heading)}</h2><ul>")
        parts.extend(_li(c) for c in items)
        parts.append("</ul>")

    parts.append(
        f'<div class="footer">{len(commits)} '
        f"change{'s' if len(commits) != 1 else ''} in total.</div>"
    )
    parts.append("</body></html>")
    return "".join(parts)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--markdown", action="store_true", help="emit Markdown")
    p.add_argument("--title", default="Release notes")
    p.add_argument("--period", default="")
    args = p.parse_args(argv)

    commits = json.load(sys.stdin)
    if args.markdown:
        print(render_markdown(commits, args.title, args.period))
    else:
        print(render_html(commits, args.title, args.period))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
