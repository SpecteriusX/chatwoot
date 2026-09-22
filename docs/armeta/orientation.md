# Chatwoot orientation — modules relevant to the Armeta ТЗ

Internal note for the Support Department platform work. Scope is deliberately narrow: only the
modules the ТЗ actually touches. This is not a tour of the codebase — per the priorities plan,
we go deeper into other areas *as needed*, not in advance.

Base: `v4.18.0` (`9f920b54`), branch `armeta/main`.

---

## 1. Conversation domain — the ticket

`app/models/conversation.rb` is the ticket model. Read this file first; it is the hub everything
else hangs off.

- **States:** `enum status: { open: 0, resolved: 1, pending: 2, snoozed: 3 }`
- **Priority:** `enum priority: { low: 0, medium: 1, high: 2, urgent: 3 }`, nullable
- **`display_id`** is the human-visible per-account ticket number, set by a **DB trigger**
  (see `load_attributes_created_by_db_triggers`), not by Rails.
- **No state machine.** The code says `# FIXME: implement state machine with aasm`. Transitions
  are plain `update!(status:)` / `toggle_status` / `bot_handoff!`. Ordering bugs are easy here.
- Status-linked bookkeeping columns move together: `status_changed_at`, `snoozed_until`,
  `waiting_since`, `first_reply_created_at`, `last_activity_at`.

Behaviour fans out from `after_update_commit` / `after_create_commit` into the listener bus,
not from inline code. Concerns live in `app/models/concerns/`: `Labelable`,
`AssignmentHandler`, `AutoAssignmentHandler`, `ActivityMessageHandler`, `SortHandler`.

**Related models**

| Model | Notes |
|---|---|
| `Message` | `message_type: incoming/outgoing/activity/template`. `activity` is the system audit line. `private: true` = internal note. `content_attributes` jsonb is where message-level custom data belongs. Has a `default_scope` ordering by `created_at`. |
| `Inbox` | `belongs_to :channel, polymorphic: true`. Holds operational config: `enable_auto_assignment`, `csat_survey_enabled`, `working_hours_enabled`, `lock_to_single_conversation`. |
| `Channel::*` | 12 types: `Api`, `Email`, `FacebookPage`, `Instagram`, `Line`, `Sms`, `Telegram`, `Tiktok`, `TwilioSms`, `TwitterProfile`, `WebWidget`, `Whatsapp`. |
| `ContactInbox` | The join identifying a contact *on a channel*. `(inbox_id, source_id)` is unique — `source_id` is the phone number, FB PSID, widget token, etc. |

Canonical creation path: `app/builders/contact_inbox_builder.rb` →
`app/builders/conversation_builder.rb` → `app/builders/messages/message_builder.rb`.

## 2. Routing and assignment (ТЗ 3.7)

**Two generations run side by side**, gated by the account feature flag `assignment_v2`.

Entry point for both: `app/models/concerns/auto_assignment_handler.rb`. It only fires when
`inbox.enable_auto_assignment?` and the conversation is unassigned.

- **V1 (legacy, online agents only)** —
  `app/services/auto_assignment/agent_assignment_service.rb` intersects allowed agents with
  *online* agents from Redis `OnlineStatusTracker`, then
  `app/services/auto_assignment/inbox_round_robin_service.rb` pops from a **Redis list per
  inbox** and re-pushes the agent to the back.
- **V2 (bulk, policy-driven)** — `app/models/assignment_policy.rb` +
  `app/services/auto_assignment/assignment_service.rb`. Scans unassigned open conversations,
  applies an age cutoff and priority ordering, and claims rows with `FOR UPDATE SKIP LOCKED`.
  Driven by `app/jobs/auto_assignment/periodic_assignment_job.rb`.

**Manual reassignment:** `POST /api/v1/accounts/:id/conversations/:id/assignments` →
`app/services/conversations/assignment_service.rb`.

**Team routing:** `Team#allow_auto_assign`. Assigning a team with it off effectively parks the
conversation for manual pickup.

Round-robin is MIT. Only *balanced* order and per-agent capacity limits are enterprise.

## 3. Labels (ТЗ 3.6)

Uses the `acts_as_taggable_on` gem. **The `labels` table is only the account-level catalog** —
actual assignments live in the generic `tags` / `taggings` tables.

- `app/models/label.rb` (catalog), `app/models/concerns/labelable.rb` (included by both
  `Conversation` and `Contact`).
- `conversations.cached_label_list` is a **denormalized** comma-string for fast list rendering.
  Read it via `cached_label_list_array`; **never write it directly.**
- Renaming a label title triggers `Labels::UpdateJob` to rewrite taggings.
- Filtering is declared in `lib/filters/filter_keys.yml` under both `conversations:` and
  `contacts:`.

## 4. Macros, canned responses, automation (ТЗ 3.9)

**Canned responses** are deliberately trivial: `app/models/canned_response.rb` is just
`short_code` + `content`, account-scoped. The `/` picker is
`dashboard/components/widgets/conversation/CannedResponse.vue`. Variables go through
`app/services/liquid/`.

**Automation rules** are the main customization surface.

- `app/models/automation_rule.rb` — `event_name`, `conditions` jsonb, `actions` jsonb,
  `execution_delay`.
- Trigger events: `conversation_created`, `conversation_updated`, `conversation_opened`,
  `conversation_resolved`, `message_created` (`app/listeners/automation_rule_listener.rb`).
- Conditions are evaluated by re-querying via `ConditionsFilterService`, a `FilterService`
  subclass driven by `lib/filters/filter_keys.yml`.
- **Actions**: `app/services/action_service.rb` is the shared vocabulary. Dispatch is literally
  `send(action[:action_name], action[:action_params])` — there is no dispatcher table to edit.
  19 actions ship: `send_message`, `add_label`, `remove_label`, `assign_team`, `assign_agent`,
  `change_status`, `change_priority`, `snooze_conversation`, `send_webhook_event`,
  `add_private_note`, and so on.
- **Macros** (`app/models/macro.rb`) reuse the same action vocabulary, agent-triggered.
- Loop protection: `Current.executed_by` stops a rule re-triggering itself.

**Adding an action** needs only a method on an `ActionService` overlay plus the name appended to
`AutomationRule#actions_attributes`. `enterprise/app/services/enterprise/action_service.rb`
(12 lines, adds `add_sla`) is the worked example.

## 5. Agent panel frontend (ТЗ 3.4)

Vue 3 + Vite. Entry: `app/javascript/entrypoints/dashboard.js` → `dashboard/App.vue`.

- **State is split.** Vuex is primary (`dashboard/store/`, ~55 modules). Pinia is installed
  alongside; new stores go in `dashboard/stores/`.
- **Routing:** `dashboard/routes/index.js` → `dashboard/dashboard.routes.js` → per-feature files.
- **Conversation screen:** `routes/dashboard/conversation/ConversationView.vue` composes
  `components/ChatList.vue` + `components/widgets/conversation/ConversationBox.vue`
  (→ `MessagesView.vue`, `ReplyBox.vue`) + `ConversationSidebar.vue`.
- **`components/` vs `components-next/`** — `components/` is the legacy Options-API tree;
  `components-next/` is the new design-system tree (`<script setup>`, Tailwind only, Histoire
  stories). **Rule: read `components/` to understand behaviour, write in `components-next/`.**
  Message bubbles *must* use `components-next/message/`.

## 6. Schema orientation

`db/schema.rb`, version `2026_08_31_000000`. Extensions: `pg_trgm`, `vector`, `pgcrypto`.

The tables that matter for ticketing:

| Table | Key columns | Notable index |
|---|---|---|
| `conversations` | `account_id`, `inbox_id`, `contact_id`, `display_id`, `status`, `priority`, `assignee_id`, `team_id`, `cached_label_list`, `waiting_since`, `snoozed_until` | `(account_id, display_id)` UNIQUE; **`conv_acid_inbid_stat_asgnid_idx (account_id, inbox_id, status, assignee_id)`** — the list-view workhorse |
| `messages` | `conversation_id`, `message_type`, `content_type`, `private`, `content`, `sender_type/id`, `content_attributes` | `(conversation_id, account_id, message_type, created_at)`; GIN trgm on `content` |
| `contact_inboxes` | `contact_id`, `inbox_id`, `source_id` | **`(inbox_id, source_id)` UNIQUE** — the channel identity key |
| `contacts` | `email`, `phone_number`, `identifier`, `custom_attributes` | GIN trgm across name/email/phone for search |
| `inboxes` | `channel_id` + `channel_type`, `enable_auto_assignment`, `csat_config` | `(channel_id, channel_type)` |
| `tags` / `taggings` | `taggable_type/id`, `context = 'labels'` | `taggings_idx` UNIQUE |
| `automation_rules` | `event_name`, `conditions`, `actions`, `execution_delay` | `account_id` |
| `custom_filters` | `name`, `query` jsonb, `user_id`, `filter_type` | saved views — see correction below |

## 7. Extension pattern — how Armeta code attaches

Full detail in [`custom/README.md`](../../custom/README.md). Summary:

`ChatwootApp.extensions` returns `%w[enterprise custom]` once `custom/` exists. The initializer
`config/initializers/01_inject_enterprise_edition_module.rb` walks that list, so
`Conversation.prepend_mod_with('Conversation')` resolves `Enterprise::Conversation` then
`Custom::Conversation`. `custom` is applied last, so **`Custom::` wins**.

There are **118 `*_mod_with` call sites** across `app/` and `lib/` — check the bottom of any core
file for its seam before considering an edit.

Prefer these seams over a class override where they fit:

- automation actions (no dispatcher edit needed)
- `lib/filters/filter_keys.yml` for new filter/automation conditions
- `custom_attribute_definitions` — become filters and automation conditions with **zero code**
- `AsyncDispatcher` listeners, rather than new Conversation callbacks
- account webhooks, for anything that can live outside the Rails process

⚠️ **`custom/lib/custom.rb` is load-bearing** — see `custom/README.md`. Deleting it breaks boot.

---

## 8. Corrections to the ТЗ

Verified against the code at `v4.18.0`. These change downstream scope and should be confirmed
with the Support Department lead.

### 8.1 ТЗ 3.5 overstates the Enterprise dependency

The ТЗ states *«SLA-политики и функция снуза входят в состав платной Enterprise-лицензии»*.
Two of the three acceptance criteria for 3.5 are **already met natively**:

| Criterion | Reality |
|---|---|
| «Приоритет» | **Already native, MIT.** `enum priority` on `Conversation`, `toggle_priority` endpoint, indexed, already usable as an automation condition *and* action (`change_priority`), with UI in `components-next/Conversation/ConversationCard/CardPriorityIcon.vue`. |
| «Снуз» | **Already native, MIT.** `snoozed` status + `snoozed_until`, returned to queue by `app/jobs/conversations/reopen_snoozed_conversations_job.rb` (every 5 min via `config/schedule.yml`), with `CustomSnoozeModal.vue` and a natural-language date parser. |
| «SLA-таймер» | **Genuinely enterprise.** All policy evaluation, timer math and breach detection is in `enterprise/`. |

So only SLA needs building. Note the schema (`sla_policies`, `applied_slas`, `sla_events`) **and
the entire SLA frontend** are MIT and reusable — re-implementation means writing the evaluation
service and the three jobs against an existing schema and existing UI, not building from zero.

### 8.2 ТЗ 3.2 — saved views are not shareable

The ТЗ treats Custom Views as *«реализовано нативно — требуется настройка»*. The acceptance
criterion *«Вьюхи доступны команде согласно ролям»* is **not** achievable by configuration:
`app/models/custom_filter.rb` has no `team_id` and no `visibility` column, and
`custom_filters_controller.rb` hard-scopes every action to `where(user: Current.user)`. Even an
administrator cannot see another agent's view. Sharing requires a migration, controller and
policy change.

### 8.3 ТЗ 3.8 — no knowledge-base search in the widget

Portal search itself is real and MIT (`pg_search_scope :text_search` on `Article`, with A/B/C
weighting). But the acceptance criterion says search must be *«встроен в виджет поддержки»*, and
the widget has **no search input at all** — `app/javascript/widget/api/article.js` exposes only
`getMostReadArticles`, and the home screen renders "Popular articles". Needs a new widget
component against the existing MIT `portal_search` route. Modest work, fully MIT.

### 8.4 ТЗ 3.3 — reports are more complete than assumed, but admin-only

All five requested metrics already exist in `app/builders/v2/reports/` (volume by channel and by
period, first response time incl. distribution, resolution time, CSAT collection *and* display,
per-agent workload both historical and live). The real gap is access control: `ReportPolicy` is
**administrator-only** in MIT, so agents cannot see reports at all without enterprise custom
roles. Worth deciding early whether agents need report access.

### 8.5 ТЗ 3.11 — n8n approach confirmed

Webhooks are native and solid: 12 events, HMAC-signed
(`X-Chatwoot-Signature: sha256=HMAC(secret, "{ts}.{body}")`), with SSRF protection.
`conversation_updated` / `contact_updated` carry a `changed_attributes` diff, which is useful for
filtering n8n-side. No Chatwoot-side development is needed.

⚠️ **Caveat:** the automation `send_webhook_event` action posts via
`WebhookJob.perform_later(url, payload)` **without a secret** — those calls are *unsigned*,
unlike account webhooks. n8n-side auth for automation-triggered flows must be URL-token based.

---

## 9. Operational findings

### 9.1 Branding reset — relevant to the `enterprise/` decision

If `enterprise/` is kept without a licence, `Internal::ReconcilePlanConfigService` runs nightly
and, when the pricing plan is `community`, calls `account.disable_features!` for every premium
feature on **every account** and force-resets branding
(`INSTALLATION_NAME`, `LOGO`, `BRAND_URL`, `TERMS_URL`) to Chatwoot defaults. On a white-labelled
Armeta production instance this would silently undo branding. The job does not exist once
`enterprise/` is removed.

### 9.2 Snooze reopen window is bounded at 3 days

`ReopenSnoozedConversationsJob` queries `where(snoozed_until: 3.days.ago..Time.current)`.
A conversation snoozed further out than 3 days, or missed while Sidekiq is down over a weekend,
**never auto-reopens**. This directly affects ТЗ 3.5's snooze criterion
(*«с автоматическим возвратом в очередь к заданному сроку»*) and is a good first candidate for a
`custom/` override.

### 9.3 Git hooks do not run on this machine

`husky` pre-commit invokes `lint-staged`, which is not installed on the host — `node_modules`
exists only inside the `vite` container volume. Commits therefore need `--no-verify`, with lint
run manually in the container:

```bash
docker compose exec -T rails bundle exec rubocop --force-exclusion <files>
```

Fix properly by running `pnpm install` on the host.
