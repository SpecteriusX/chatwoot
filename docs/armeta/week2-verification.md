# Week 2 — verification of out-of-the-box functionality

Verifies ТЗ 3.6 (теггинг), 3.7 (маршрутизация и переадресация) and 3.9 (макросы, шаблоны,
автоматизация) against a live instance, per the priorities plan Week 2.

Instance: `armeta/main` @ `v4.18.0`, local Docker. Account 1 «Acme Inc».
Everything below was exercised through the **public API or admin-level config**, not by patching
code — which is itself part of what the ТЗ asks us to confirm.

**Result: all three blocks pass.** No development is required for 3.6, 3.7 or 3.9. What remains
is content configuration, which needs business input rather than engineering.

---

## ТЗ 3.6 — Теггинг переписок и контактов ✅

| Criterion | Result | Evidence |
|---|---|---|
| «Теги создаются и редактируются без участия разработчика» | **PASS** | `POST /api/v1/accounts/1/labels` created `billing`; `PATCH .../labels/1` changed description and colour. Both 200, no code change. |
| «Теги применимы к переписке и к контакту» | **PASS** | `POST .../conversations/35/labels` and `POST .../contacts/1/labels`, both returned `{"payload":["billing"]}`. |
| «…фильтруемы во вьюхах» | **PASS** | `POST .../conversations/filter` with `attribute_key: labels` → 1 match. Same filter on `/contacts/filter` → 1 match (`jane`). |
| «…и в отчётности» | **PASS** | `GET /api/v2/accounts/1/summary_reports/label` → `[{"name":"billing","conversations_count":1,…}]`. `GET /api/v2/accounts/1/reports/labels` returns the CSV export. |

Note the report routes are `summary_reports/label` (singular) and `reports/labels` (plural) —
easy to get wrong.

## ТЗ 3.7 — Маршрутизация и переадресация ✅

Tested on a dedicated inbox #34 «Routing Test» to avoid interference (see Finding 3).

| Criterion | Result | Evidence |
|---|---|---|
| «Новые обращения распределяются по правилу round-robin» | **PASS** | 4 conversations, 2 online agents → `#36 john`, `#37 agent2`, `#38 john`, `#39 agent2`. Clean alternation, 2 each. |
| «Агент или руководитель может вручную перепривязать тикет» | **PASS** | `POST .../conversations/36/assignments` with `assignee_id: 34` → 200, reassigned john → agent2. |
| «Правила маршрутизации редактируются без изменения кода» | **PASS** | `PATCH .../assignment_policies/1` changed `conversation_priority` to `longest_waiting` and `fair_distribution_limit` to 5 → 200. |

## ТЗ 3.9 — Макросы, шаблоны, автоматизация ✅

| Criterion | Result | Evidence |
|---|---|---|
| Макросы | **PASS (capability)** | Macro «Escalate billing issue» created via API with 3 actions (`add_label`, `change_priority`, `add_private_note`). Executed on conversation #38 via `MacrosExecutionJob` → `labels=["billing"] priority="high"` + 1 private note. |
| Автоматизация | **PASS (capability)** | Rule «Auto-tag billing by keyword» on `message_created`, condition `content contains "invoice"`, actions `add_label` + `change_priority`. An incoming message *"…question about my invoice…"* on a new conversation #40 produced `labels=["billing"], priority="high"` with no manual step. |

⚠️ Both criteria are phrased as *«настроен согласованный набор»* and *«не менее 3–5 правил»* —
i.e. they are satisfied by **content**, not capability. The platform side is proven; agreeing the
actual macro set and the 3–5 rules needs Support Department input on real scenarios. That is a
business dependency to raise now, like the Help Center data request.

---

## Findings worth acting on

### 1. `assignment_v2` without an assignment policy silently disables auto-assignment ⚠️

On this account `assignment_v2` was already enabled, which routes assignment through the V2
service (`app/services/auto_assignment/assignment_service.rb`) and **bypasses the V1 path
entirely** (`app/models/concerns/auto_assignment_handler.rb#run_legacy_auto_assignment` returns
early when `inbox.auto_assignment_v2_enabled?`).

But `Inbox#auto_assignment_v2_enabled?` checks only the **account feature flag** — not whether a
policy exists. With the flag on and no `AssignmentPolicy` attached, nothing assigns and nothing
errors. Initially 4 test conversations sat unassigned with no log output.

**Action:** make attaching an `AssignmentPolicy` part of inbox setup whenever `assignment_v2` is
on. Worth a `custom/` guard or an admin-visible warning later.

### 2. Round-robin only considers **online** agents

`Inbox#available_agents` (`app/models/concerns/inbox_agent_availability.rb`) intersects inbox
members with online user ids from the Redis `OnlineStatusTracker`, and
`perform_bulk_assignment` returns early when that set is empty. Offline agents receive nothing.

This is correct product behaviour, but it means **round-robin cannot be demonstrated or tested
without agents actually being online** — the assignment simply no-ops. Assignment was verified
only after marking both agents present via `OnlineStatusTracker.update_presence`.

Operationally: out-of-hours traffic accumulates unassigned rather than being pre-distributed.
Confirm that matches how Support Department wants nights and weekends handled.

### 3. An active Captain assistant blocks human auto-assignment on that inbox

`should_run_auto_assignment?` returns false when `assignee_agent_bot_id.present?`. Inbox #1 has
the Captain sandbox attached and `captain_active?` is true, so AI-owned conversations are never
auto-distributed to agents until `bot_handoff!` runs. This is why testing used a separate inbox.

Not a defect — but relevant if AI returns to scope later: the bot and round-robin compete for the
same conversations.

### 4. Clear Sidekiq retry/dead sets after a version switch

After moving `develop` → `v4.18.0`, queued jobs serialized against the old code failed on retry
with `ArgumentError: You tried to define an enum named "locale" on the model "Account"…` — 730 log
occurrences, 67 dead jobs. Alarming, but purely stale payloads; clearing the sets removed it and
fresh jobs run clean.

**Action:** add "clear `Sidekiq::RetrySet` / `Sidekiq::DeadSet`" to the upstream-upgrade runbook.
This will recur on every version bump, and ТЗ 2.6 already flags upgrades as a standing risk.

---

## Test data left on the instance

Left in place as evidence; delete when no longer useful.

- Inbox **#34 «Routing Test»** (web widget) + assignment policy «Armeta Round Robin»
- User **agent2@acme.inc** (agent role, password as per the seed convention)
- Label **billing**; macro **«Escalate billing issue»**; automation rule **«Auto-tag billing by keyword»**
- Contacts `RR Tester 1–4`, `Automation Tester`; conversations #36–#40
