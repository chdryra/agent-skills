---
description: Create tickets in Linear or Jira from a finding or planned work — includes why/what/criteria/test plan and a suggested model for implementation and review.
---

# Ticket creation

Turn a problem, finding, or planned piece of work into **one or more** tickets, written so a cheaper model can implement them cold.

## How many tickets

Decide the split yourself; don't ask unless the scope is genuinely ambiguous. One ticket per independently shippable, independently reviewable change. Split when parts touch different subsystems, have different priorities, or could land in separate PRs. Keep together what only makes sense as one diff. If tickets depend on each other, state the ordering explicitly in each description and avoid pairs that touch the same files in parallel.

## Ticket format

Title: imperative, specific ("Fail closed in auth middleware; inject DB at construction" — not "Fix auth").

Description (markdown), in this order:

1. **Why** — the problem and its impact, with concrete evidence: `file:line` references, current behaviour vs intended. A reader should be convinced the change matters without opening the repo.
2. **What to do** — numbered steps naming exact files and functions. Spell out the target design, not just the complaint. Include code sketches where the shape matters.
3. **Acceptance criteria** — checklist of observable outcomes (behaviour, not implementation details).
4. **Test plan** — which existing tests must pass, which new tests to add and where.
5. **Suggested model** — one line each for implementation and review, with the reason.

### Priority

1 = Urgent (exploitable security hole, data loss), 2 = High (correctness/integrity bugs, DoS), 3 = Medium (maintainability, structure), 4 = Low (hygiene, naming, tooling).

### Model suggestion heuristic

The deciding factor is how much judgment is left after the spec, not difficulty:
- **Sonnet** to implement when the ticket fully specifies the change (files, steps, criteria).
- **Opus** to implement when cross-cutting judgment remains (many call sites, design trade-offs left open).
- **Opus review before merging any security-sensitive diff** (auth, rate limiting, transactions, permissions) regardless of who implements.

---

## Detecting the issue tracker

Check in this order:
1. Are Linear MCP tools available (`mcp__linear__*`)? → Use Linear.
2. Does the project have a `JIRA_URL` / `JIRA_PROJECT` env var, or a `.jira` / `jira.config.json` config file? → Use Jira.
3. Check memory for a previously noted tracker preference.
4. Ask the user which tracker to use and what project/team to file against.

---

## Creating tickets in Linear

**Preferred:** use Linear MCP tools if available (`mcp__linear__save_issue`).

**Fallback:** GraphQL API. Find the key in this order, read it programmatically, and **never echo it**: a `LINEAR_API_KEY` environment variable; or — *Claude Code only* — `~/.claude.json` → `mcpServers.linear.env.LINEAR_API_KEY`.

First look up the team so you use the right `teamId`:

```python
import json, urllib.request
# key = <loaded from config>
query = '{ teams { nodes { id name key } } }'
req = urllib.request.Request('https://api.linear.app/graphql',
                             headers={'Authorization': key, 'Content-Type': 'application/json'},
                             data=json.dumps({'query': query}).encode())
teams = json.load(urllib.request.urlopen(req))['data']['teams']['nodes']
# Pick the matching team, confirm with user if ambiguous
```

Then create the issue:

```python
query = 'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { identifier url } } }'
payload = {'query': query, 'variables': {'input': {
    'teamId': '<teamId from lookup>',
    'title': '<title>',
    'description': '<markdown description>',
    'priority': 2,  # 1=Urgent 2=High 3=Medium 4=Low
}}}
req = urllib.request.Request('https://api.linear.app/graphql',
                             headers={'Authorization': key, 'Content-Type': 'application/json'},
                             data=json.dumps(payload).encode())
print(json.load(urllib.request.urlopen(req)))
```

---

## Creating tickets in Jira

**Preferred:** use Jira MCP tools if available.

**Fallback:** REST API (v3). You need:
- `JIRA_URL` — base URL, e.g. `https://yourorg.atlassian.net`
- `JIRA_PROJECT` — project key, e.g. `PROJ`
- Auth token — check a `JIRA_API_TOKEN` env var first; or — *Claude Code only* — `~/.claude.json`. **Never echo it.**

```python
import json, urllib.request, os
base_url = os.environ.get('JIRA_URL')
project_key = os.environ.get('JIRA_PROJECT')
token = '<loaded from config>'
headers = {
    'Authorization': f'Bearer {token}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
}

priority_map = {1: 'Highest', 2: 'High', 3: 'Medium', 4: 'Low'}

payload = {
    'fields': {
        'project': {'key': project_key},
        'summary': '<title>',
        'description': {
            'type': 'doc', 'version': 1,
            'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': '<description>'}]}]
        },
        'issuetype': {'name': 'Task'},
        'priority': {'name': priority_map[2]},
    }
}
req = urllib.request.Request(f'{base_url}/rest/api/3/issue',
                             headers=headers, data=json.dumps(payload).encode())
result = json.load(urllib.request.urlopen(req))
print(result['key'], result['self'])
```

Note: Jira's description uses Atlassian Document Format (ADF). For rich markdown content, convert each section into ADF nodes. Simple prose works fine as a single paragraph node.

---

## Afterwards

- Report each ticket to the user: identifier, link, priority, suggested models, and any sequencing constraints.
- Offer to log the tickets in the project journal (`/journal`, under **Planned**).
