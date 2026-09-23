# Security and robustness review — 2026-09-23

Authorised testing against the local instance (`armeta/main` @ v4.18.0). Covers authorization,
input validation, injection, and the unauthenticated public surface.

**Result: no authorization or injection vulnerabilities found. Six robustness defects fixed
(500 → 422). Two findings reported for decision rather than changed.**

---

## Verified secure — no action needed

| Test | Result |
|---|---|
| Cross-account access (agent in account 1 → account 2 resources) | **401** on conversations, contacts, inboxes, labels, agents, automation_rules, macros |
| Privilege escalation (agent → admin-only endpoints) | **401** on reports, automation rules, webhooks, account update, label create |
| Unauthenticated API access | **401** |
| IDOR by resource id (`/conversations/99999`) | **404** — no cross-tenant leakage |
| Widget endpoints without a contact token | **404** on messages, conversations, contact, labels |
| Bogus `website_token` | **404** |

### SQL injection — not exploitable

`FilterService` builds a SQL `WHERE` string from user input, so it was tested directly.

- `attribute_key`, `filter_operator`, `query_operator` are whitelist-validated → **422**
- `values` are **parameterised**: `status = "open' OR 1=1--"` returned **0 rows**, not all 15.
  Interpolation would have returned everything.

What an agent can read at `GET /api/v1/accounts/1` was also checked: account name, locale,
feature list and cache keys. No secrets.

---

## Fixed — malformed input returned 500 instead of 422

All six reached the model layer and raised unhandled exceptions. Per `CLAUDE.md`, invalid input
should be rejected at the controller boundary with 422; a 500 also means Sentry noise in
production.

| # | Endpoint | Input | Was | Now |
|---|---|---|---|---|
| 1 | `conversations/filter`, `contacts/filter` | missing `payload`, or `payload` not an array | 500 | 422 |
| 2 | `conversations/:id/toggle_status` | `status` not a valid enum | 500 | 422 |
| 3 | `conversations/:id/toggle_status` | unparseable `snoozed_until` | 500 | 422 |
| 4 | `macros` | `actions` not an array | 500 | 422 |
| 5 | `automation_rules` | `conditions` or `actions` not an array | 500 | 422 |
| 6 | `automation_rules` | unsupported `event_name` | **200** | 422 |

**Root causes**

1. `FilterService#validate_query_operator` called `@params[:payload].each_with_index` with no
   type check. Added `CustomExceptions::CustomFilter::InvalidPayload`, raised before iteration
   and rescued by both controllers.
2 & 3. `set_conversation_status` assigned an invalid enum (`ArgumentError`) and called
   `DateTime.strptime(str, '%s')` on arbitrary text (`Date::Error`). Both now validated,
   following the existing `permitted_update_params` pattern of raising
   `ActionController::ParameterMissing`, which the global handler renders as 422.
4. `AttachmentConcern#validate_and_prepare_attachments` called `actions.map` at the controller
   layer, *before* model validation, so model-level guards never ran. Guarded there — one fix
   covering all four call sites (macro and automation rule, create and update).
5. Four validators iterate `conditions` (`json_conditions_format`, `query_operator_presence`,
   `query_operator_value`, `execution_delay_supported_*`). Rails runs every validator, so
   guarding only the first still crashed in the others. All now guarded, with
   `json_conditions_format` reporting the error.
6. `event_name` had no validation at all, so a typo created a rule that silently never fired.
   One was found in the database during this review (`event_name: "nope"`). Added
   `SUPPORTED_EVENT_NAMES`; all five real events verified still accepted.

Verified after: **0 of 11 malformed requests return 500**, and every valid operation still works.

---

## Reported — decision needed, not changed

### 1. Agent roster disclosure via the widget

`GET /api/v1/widget/inbox_members?website_token=...` returns **every** inbox member — full name,
user id and live availability — to an **unauthenticated** caller. The controller does
`skip_before_action :set_contact`, and `website_token` is public by design: it is embedded in the
widget snippet on every page that runs the chat.

```json
{"payload":[{"id":1,"name":"John","availability_status":"online"},
            {"id":35,"name":"Maria Petrova","availability_status":"offline"}, ...]}
```

Risk is employee enumeration for phishing, plus live presence useful for timing social
engineering. Agent names do become known through normal conversation, so the incremental leak is
the **full roster including agents who are never online**, and presence before any contact.

This is upstream behaviour, not a regression from our changes. The widget genuinely needs it —
`TeamAvailability.vue` and `ChatHeader.vue` render available agents.

**Why not fixed here:** the client already filters to `availability_status === 'online'`, so
returning only online agents would lose nothing visually. But `availability_status` is computed
(`user_availability_status`) from the DB `availability` column *combined with* Redis presence and
the `auto_offline` flag — a naive `where(availability: :online)` would be wrong and could break
the "We are online" indicator. Worth doing deliberately, with tests, not inside a review pass.

### 2. Invalid `assignee_id` silently unassigns

`POST /conversations/:id/assignments` with `assignee_id: 99999` returns **200** and leaves the
conversation **unassigned** — verified: assignee went from `maria@acme.inc` to `nil`.

`Conversations::AssignmentService#assignee` is `account.users.find_by(id: assignee_id)`, which
returns nil for both "not supplied" and "not found". Unassigning depends on that nil, so a
mistyped id is indistinguishable from an intentional unassign.

**Why not fixed here:** distinguishing them means erroring when `assignee_id` is present but
unresolvable. Clients that unassign by sending `0` or `""` would break (`0.present?` is true).
Needs a check of what the dashboard and any API consumers actually send.

---

## Not covered

Rate limiting, CSRF on session endpoints, file-upload handling, ActionCable authorization, and
webhook SSRF (`SafeFetch` exists but was not exercised). Worth a second pass before production.
