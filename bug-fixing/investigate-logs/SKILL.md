---
name: investigate-logs
description: Investigate a production error from a GCP Cloud Logging URL. Parses the URL for query filters, detects the runtime (GKE, Cloud Run, App Engine, Compute Engine, Cloud Functions, Dataflow, Vertex AI, etc.), queries logs via the gcloud CLI, traces the failure across services/instances by correlation ID, reconstructs full tracebacks, follows the error through the codebase to root cause, and writes up findings to a wiki (Notion, Confluence, or other). Use when someone shares a GCP logs link to investigate.
argument-hint: <gcp-logs-url>
allowed-tools: Bash, Read, Edit, Glob, Grep, Agent
---

# investigate-logs

Investigate a production error from a GCP Cloud Logging URL. Parses the query, fetches logs via `gcloud`, traces the error across services by correlation ID, identifies root cause in the codebase, and writes up the findings.

**Usage:**
```
/investigate-logs <gcp-logs-url>
```

**Example:**
```
/investigate-logs "https://console.cloud.google.com/logs/query;query=...;startTime=...;endTime=...?project=<project-id>"
```

**Prerequisites:**
- `gcloud` CLI authenticated with read access to the GCP project.
- A wiki for the write-up — Notion, Confluence, or other (detected; see Step 6). Optional: if no wiki is available, the findings are returned in the conversation instead.

---

## Step 1 — Parse the GCP logs URL

The argument is a GCP Cloud Logging console URL. Extract these (they are URL-encoded):

- **`query`** — the log filter (after `/logs/query;query=` in the URL path segment).
- **`startTime`** / **`endTime`** — time range.
- **`project`** — GCP project ID (the `?project=` query parameter).
- **`cursorTimestamp`** — optional, the timestamp the user was looking at.
- **`summaryFields`** — optional, hints at which fields are interesting.

The `query` parameter uses Cloud Logging filter syntax. Common patterns:
- `"some-uuid"` — a correlation ID or text search.
- `resource.type="<type>"` — restrict to one runtime (see Step 1a).
- `resource.labels.<label>="<value>"` — filter on a runtime-specific label.
- `-protoPayload.serviceName="storage.googleapis.com"` — exclusion filter.
- A bare service name — text search.

**Important:** the leading `--` in a Cloud Logging UI filter means "show all fields" — it is not a filter operator. Strip it. `gcloud logging read` also uses slightly different syntax, so convert:
- Drop the `--` prefix.
- Join terms with `AND` (not newlines).
- Exclusions (`-field=value`) become `NOT field=value`.
- Regex (`=~`) works as-is.

Identify the **correlation ID** (usually a quoted UUID), the **time range**, the **project**, and any **resource filters** already present in the query (these tell you the runtime — see next).

### Step 1a — Identify the runtime (resource type)

Don't assume Kubernetes. Cloud Logging tags every entry with a `resource.type` and runtime-specific `resource.labels`, and the label you group/filter by differs per runtime. If the URL's query already pins a `resource.type` or a tell-tale label (e.g. `pod_name`, `service_name`, `instance_id`), use that. Otherwise run one broad query (Step 2) and read `resource.type` off the first results.

Map it with this reference — the **"group by" label** is the per-instance identifier you'll use in place of "pod" throughout the rest of this skill:

| Runtime | `resource.type` | Key labels | Group by (per-instance) |
|---|---|---|---|
| GKE / Kubernetes | `k8s_container` | `cluster_name`, `namespace_name`, `pod_name`, `container_name` | `pod_name` |
| Cloud Run (service) | `cloud_run_revision` | `service_name`, `revision_name`, `location` | `service_name` |
| Cloud Run (job) | `cloud_run_job` | `job_name`, `location` | `job_name` |
| App Engine | `gae_app` | `module_id`, `version_id` | `module_id` |
| Compute Engine VM | `gce_instance` | `instance_id`, `zone` | `instance_id` |
| Cloud Functions | `cloud_function` | `function_name`, `region` | `function_name` |
| Dataflow | `dataflow_step` | `job_id`, `job_name`, `step_id` | `job_name` |
| Vertex AI custom job | `ml_job` | `job_id`, `task_name` | `job_id` |
| Cloud audit logs | `audited_resource` / others | `protoPayload.serviceName`, `methodName` | service name |

If the runtime isn't listed, inspect a sample entry's `resource.labels` (`gcloud logging read ... --format='json(resource)' --limit=1`) and pick the label that uniquely names one running instance/service. Throughout the rest of this skill, **"<instance-label>"** means that group-by label for your runtime (`pod_name`, `service_name`, `instance_id`, …) and **"<scope-filter>"** means whatever top-level filter scopes the query (e.g. `resource.labels.cluster_name="<cluster>"` on GKE, `resource.labels.service_name="<svc>"` on Cloud Run, or just `resource.type="<type>"`).

---

## Step 2 — Initial log query

Run a broad query using the correlation ID (scoped by the runtime filter from Step 1a) to find every instance that logged this ID:

```bash
gcloud logging read '"<correlation-id>" AND <scope-filter>' \
  --project=<project> --format=json --freshness=2d --limit=100
# e.g. GKE:        ... AND resource.labels.cluster_name="<cluster>"
#      Cloud Run:  ... AND resource.type="cloud_run_revision"
#      GCE VM:     ... AND resource.type="gce_instance"
```

If you didn't already know the runtime, read `resource.type` off these results and pick your `<instance-label>` from the Step 1a table before narrowing.

**gcloud notes:**
- `--freshness=2d` covers recent logs; increase for older time ranges.
- `--limit=100` is a good starting point; raise if needed.
- `--format=json` gives structured output for parsing; pipe large output through `python3` to summarise.

From the results, identify:
1. **All instances** that logged this correlation ID (group by `resource.labels.<instance-label>`).
2. **All services / components** involved (group by `resource.type` and any service-name label).
3. **Severity distribution** — are there ERROR entries? In which instances?
4. **Timeline** — what happened first, what happened last?

---

## Step 3 — Find the root error

The initial query often returns downstream *effects* (e.g. a worker receiving an error status from upstream) rather than the root cause.

### 3a — Identify the originating service

Order events chronologically — the earliest error is usually closest to the root cause. General heuristics that hold across most service topologies:
- **Queue/event-consumer workers** (Celery, PubSub, Kafka consumers) typically log the *effect* — they receive an already-failed status from upstream.
- **Compute / worker services** that do the actual processing typically log the *cause* — the crash originates here.
- **gRPC/HTTP front services** handle the inbound request and may log a wrapped error.
- **Cloud audit logs** (e.g. `protoPayload.serviceName="storage.googleapis.com"`) reveal missing objects, denied permissions, etc.

Map these roles onto the specific service names you found in Step 2 before narrowing.

### 3b — Query the originating service specifically

```bash
gcloud logging read '"<correlation-id>" AND resource.labels.<instance-label>:"<service-name>" AND severity>=ERROR' \
  --project=<project> --format=json --freshness=2d --limit=50
```

If nothing comes back with `severity>=ERROR`, drop the severity filter — the service may log errors at a different level.

### 3c — Reconstruct full tracebacks

GCP often splits multi-line log entries (like stack traces) across separate records. To rebuild a complete traceback, query around the error timestamp from the same instance:

```bash
gcloud logging read 'resource.labels.<instance-label>:"<instance-name>" AND severity>=ERROR AND timestamp>="<start>" AND timestamp<="<end>" AND textPayload:"Traceback"' \
  --project=<project> --format='json(timestamp,textPayload)' --limit=10
```

Watch for two linked exceptions:
1. The **original exception** (the underlying failure).
2. The **wrapping exception** (a higher-level error type the service raises around it). Wrapping errors often carry an application-specific code — note it; it usually pinpoints the failing subsystem.

(Adapt `"Traceback"` to the language: e.g. `"Exception in thread"` for the JVM, `"panic:"` for Go, `"at "` stack frames for Node.)

### 3d — Check cloud audit logs if relevant

If errors mention missing objects (e.g. a storage object that was never written):

```bash
gcloud logging read '"<correlation-id>" AND NOT resource.labels.<instance-label>:"<known-instances>"' \
  --project=<project> --format=json --freshness=2d --limit=20
```

For GCS, look for `storage.objects.get` with `status.code: 5` ("No such object") to confirm which files were never written.

---

## Step 4 — Trace through the codebase

From the traceback, extract file paths and line numbers. Container paths usually need mapping to the repo — strip the in-container prefix (e.g. `/app/src/...` → `src/...`, or wherever the service's source root is).

1. **Read the crashing function** at the line from the traceback.
2. **Understand the logic** — read enough surrounding context to see what condition triggered the error.
3. **Follow the call chain** — trace backwards through the frames to see how the bad state was reached.
4. **Identify the data condition** — work out what input could drive this code path.
5. **Check related code** — `Grep` for other callers, input parsing, and validation.

For each frame, note what it does, what preconditions it assumes, and what could violate them.

---

## Step 5 — Build the root cause analysis

Assemble the full picture:

1. **Error chain** — from root cause to user-visible effect, with timestamps.
2. **Root cause** — the specific code path and data condition that triggered the failure.
3. **Why it happened** — the upstream change, data issue, or latent bug behind it.
4. **Downstream impact** — what broke as a result (missing files, retries, error status).
5. **Affected scope** — which user / project / request / job ID.
6. **Suggested fix** — concrete options, with trade-offs.

---

## Step 6 — Write up the findings

Write the investigation up to your team's wiki. **Detect the wiki** in this order (same ladder as the other skills):

1. Notion MCP tools available (`mcp__notion__*`)? → Notion.
2. A `CONFLUENCE_URL` env var, or Confluence MCP tools? → Confluence.
3. Check memory for a previously noted wiki preference.
4. No wiki available? → return the write-up in the conversation and skip page creation.

Use this structure:

```
# Summary
<1–3 sentence overview: what failed, for whom, root cause>
Key identifiers (job/request ID, project, runtime + resource, revision, time range)

# Error
The crash location, full traceback, error type/code

# Root cause analysis
Detailed explanation of the bug, with code snippets
The specific data condition that triggers it
Why only certain cases are affected

# Downstream impact
Chain of effects from the root error to the user-visible failure

# Evidence from logs
Timeline of log entries supporting the analysis
Resource/instance names, timestamps, error patterns

# Suggested fix
Concrete options, with trade-offs
```

**Notion:** create a page with `API-post-page`. The `mcp__notion__API-patch-block-children` tool accepts `paragraph` and `bulleted_list_item` blocks; for headings and code blocks call the Notion REST API directly. Read any token in this order — programmatically, **never echo it**: a memory file, a `NOTION_API_KEY` env var, or — *Claude Code only* — `~/.claude.json` under `mcpServers.notion.env`.

**Confluence:** `POST /rest/api/content` with `type: page` and the title; auth via `Authorization: Basic base64(email:token)` from env/config, never hardcoded.

**IMPORTANT:** the final message to the user MUST include the page URL (or, if no wiki was available, the full write-up). This is the primary deliverable:

```
Investigation written up: <page-url>
```

---

## Notes

- Don't assume the runtime — detect `resource.type` first (Step 1a). The same methodology works whether the workload runs on GKE, Cloud Run, App Engine, Compute Engine, Cloud Functions, Dataflow, or Vertex AI; only the group-by label changes.
- Start broad (all instances for a correlation ID), then narrow. The first instance you look at is often not the one with the root cause.
- Multi-line stack traces are frequently split across separate log records at the same timestamp. Query by timestamp range + instance + a traceback marker to reconstruct them.
- The `--` prefix in GCP UI filters means "show all fields" — strip it for the CLI.
- Cloud audit logs are excluded by default in many saved queries (`-protoPayload.serviceName="storage.googleapis.com"`). Re-include them if you suspect missing objects or permission denials.
- Wrapping exceptions with application-specific codes are your fastest signpost to the failing subsystem — record the code and grep the codebase for where it's raised.
- Correlation IDs are often a domain entity ID (a job, request, or forecast UUID) that appears both in structured fields and as free text in messages. Search both.
- Map service *roles* (consumer vs. compute vs. front-end vs. audit) onto the actual service names per repo — see Step 3a.

---

## Learnings

*Populated automatically after each investigation. Keep entries generic — root cause in one sentence plus any non-obvious debugging technique. Do NOT record private or commercial specifics (real IDs, user emails, customer names, internal service codenames); those belong only in the wiki write-up.*
