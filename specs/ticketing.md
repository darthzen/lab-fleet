# Agentic Ticketing System — Spec

## Purpose

A standalone ticket store for project management across agents. It holds projects, tickets, agent assignments, model configurations, and cost data. It does not dispatch work itself; it exposes an API surface that a dispatcher (Hermes, a future routing service, or a human) can read from and write to.

## Core Entities

### Project
- `id` (string, e.g. `gwen-redesign`)
- `name` (string)
- `description` (string, optional)
- `created_at` (ISO 8601)
- `updated_at` (ISO 8601)
- `status` (`active` | `paused` | `done` | `archived`)

### Ticket
- `id` (string, e.g. `gwen-redesign-001`)
- `project_id` (string, references Project)
- `title` (string)
- `body` (string, markdown — what to do)
- `success_criteria` (string, markdown — how to know it's done)
- `status` (`open` | `in_progress` | `blocked` | `done` | `cancelled`)
- `priority` (`low` | `medium` | `high` | `urgent`)
- `assignee` (string, agent name or `unassigned`)
- `model_config` (object, see below)
- `depends_on` (array of ticket IDs)
- `created_at` (ISO 8601)
`updated_at` (ISO 8601)
- `completed_at` (ISO 8601, nullable)
- `cost` (object, see below)
- `history` (array of events, see below)

### ModelConfig
- `model` (string, e.g. `qwen/qwen3.8-27b`, `@preset/gwen-front`, `openrouter/auto`)
- `temperature` (number, optional)
- `top_p` (number, optional)
- `top_k` (integer, optional)
- `min_p` (number, optional)
- `max_tokens` (integer, optional)
- `context_window` (integer, optional)
- `provider` (string, optional, e.g. `openrouter`, `llama-server`, `ollama`)
- `extra` (object, optional, for provider-specific params)

### Cost
- `currency` (string, e.g. `USD`)
- `input_tokens` (integer)
- `output_tokens` (integer)
- `input_cost` (number)
- `output_cost` (number)
- `total_cost` (number)
- `duration_seconds` (integer)
- `model_actual` (string, the model that actually ran, if different from `model_config.model`)

### History Event
- `timestamp` (ISO 8601)
- `type` (`created` | `assigned` | `status_change` | `comment` | `model_change` | `cost_recorded` | `completed` | `failed` | `reopened`)
- `actor` (string, agent name or `human`)
- `detail` (string, optional)
- `data` (object, optional, type-specific payload)

## API Surface

### Projects
- `GET /projects` — list all projects (filter by status)
- `GET /projects/:id` — get one project
- `POST /projects` — create project
- `PATCH /projects/:id` — update project (name, description, status)
- `DELETE /projects/:id` — archive project (soft delete)

### Tickets
- `GET /tickets` — list tickets (filter by project, status, assignee, priority)
- `GET /tickets/:id` — get one ticket with full history
- `POST /tickets` — create ticket
- `PATCH /tickets/:id` — update ticket (title, body, success_criteria, priority, status, assignee, model_config, depends_on)
- `POST /tickets/:id/claim` — dispatcher claims a ticket (sets status to `in_progress`, records actor)
- `POST /tickets/:id/complete` — mark done, record cost, set `completed_at`
- `POST /tickets/:id/fail` — mark failed, record error detail
- `POST /tickets/:id/reopen` — move back to `open` or `in_progress`
- `POST /tickets/:id/comments` — add a comment
- `DELETE /tickets/:id` — cancel ticket

### Agents
- `GET /agents` — list known agents (derived from ticket assignees + explicit registration)
- `POST /agents` — register an agent (name, capabilities, default_model_config)
- `PATCH /agents/:name` — update agent config
- `GET /agents/:name/tickets` — tickets assigned to this agent

### Cost Aggregation
- `GET /costs/by-project` — total cost per project
- `GET /costs/by-model` — total cost per model (across all tickets)
- `GET /costs/by-agent` — total cost per agent
- `GET /costs/by-period` — cost over time (daily, weekly, monthly)
- `GET /costs/summary` — overall totals, average cost per ticket, most expensive model

### Dispatcher Hooks
- `GET /tickets/ready` — tickets that are `open`, have no unmet dependencies, and are unassigned or assigned to a specific agent (for polling dispatchers)
- `POST /tickets/:id/heartbeat` — agent reports it's still working (prevents timeout-based reclaim)
- `GET /tickets/in-progress` — all tickets currently in progress, with last heartbeat timestamp

## Storage

Plain JSON files on a PVC, matching the existing pattern (Gwen uses JSON files on `gwen-data` PVC).

```
/data/
  projects/
    gwen-redesign.json
  tickets/
    gwen-redesign-001.json
    gwen-redesign-002.json
  agents/
    ops.json
    gwen.json
  costs/
    2026-11.json   # monthly rollup
```

Each ticket file is self-contained: it includes the ticket object, its full history array, and its cost record. No cross-file joins needed for a single ticket.

## State Machine

```
open → in_progress → done
  ↘ blocked ↗
  ↘ cancelled
done → open (reopen)
```

Transitions:
- `open → in_progress`: dispatcher claims, or human assigns
- `in_progress → done`: agent reports success (cost recorded)
- `in_progress → blocked`: agent reports blocker (detail required)
- `in_progress → open`: agent releases, or timeout without heartbeat
- `blocked → in_progress`: blocker resolved
- `blocked → open`: deprioritized
- `done → open`: human reopens
- `* → cancelled`: human cancels (any state)

## Model Config & Cost Tracking

The `model_config` on a ticket records what the agent **should** use. The `cost.model_actual` records what **actually** ran (they may differ if the model falls back or the dispatcher overrides).

Cost is recorded by the agent (or dispatcher) at completion:
- The agent reports token counts and duration.
- The ticketing service looks up the price for `model_actual` from a price table (maintained in a config file or fetched from the provider API).
- `total_cost = input_cost + output_cost` is computed and stored.

Price table format (`/data/prices.json`):
```json
{
  "qwen/qwen3.8-27b": { "input_per_mtok": 0.60, "output_per_mtok": 1.80 },
  "openrouter/auto": { "input_per_mtok": 1.00, "output_per_mtok": 3.00 },
  "llama-server:local": { "input_per_mtok": 0.00, "output_per_mtok": 0.00 }
}
```

Local models (llama-server, Ollama) have zero API cost; the cost metric for those is primarily `duration_seconds` and `model_actual` (to track which local model was used).

## Dispatcher Integration

The ticketing service is passive. A dispatcher:

1. Polls `GET /tickets/ready?assignee=ops` (or without `assignee` for unclaimed work).
2. Calls `POST /tickets/:id/claim` to take ownership.
3. Spawns an agent session with the ticket's `body`, `success_criteria`, and `model_config`.
4. Periodically calls `POST /tickets/:id/heartbeat` (e.g. every 60s).
5. On completion, calls `POST /tickets/:id/complete` with cost data.
6. On failure, calls `POST /tickets/:id/fail` with error detail.

The ticketing service does not know how to spawn agents, route work, or manage sessions. It only stores state and enforces the state machine.

## Success Criteria for the Service Itself

- A human can create a project and tickets via the API.
- A dispatcher can poll for ready tickets, claim them, and report completion with cost.
- Cost aggregation endpoints return correct totals by project, model, agent, and period.
- Ticket history is append-only and records every state transition.
- The service survives a pod restart (all state on PVC).
- A ticket with unmet dependencies does not appear in `GET /tickets/ready`.

## Open Questions

1. **Auth:** Bearer token from an env var (matching the Google Workspace MCP pattern), or no auth (ClusterIP-only)?
2. **Web UI:** Is a minimal web frontend in scope, or is the API sufficient for now?
3. **Notifications:** Should the service push events (e.g. ticket completed) to a webhook, or is polling sufficient?
4. **Price table updates:** Manual edit, or auto-fetch from OpenRouter's model pricing API?
5. **Retention:** Do completed tickets stay forever, or is there an archive policy?

## First Implementation Target

The `gwen` service repo, as a new `ticketing/` directory or a standalone repo `darthzen/ticketing`. TypeScript, Node 22, matching the existing code standards. The first milestone is the API surface with JSON file storage and the cost aggregation endpoints.