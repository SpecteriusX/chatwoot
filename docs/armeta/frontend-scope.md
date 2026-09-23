# Frontend scope — elements proposed for removal

Proposal for review by the analyst and the Support Department lead. Nothing here has been
applied. Mapped against ТЗ «Тикетинг-платформа Support Department на базе Chatwoot», §3.1–3.11.

Instance: `armeta/main` @ `v4.18.0`.

**Key point: most of this is feature flags, not code.** Super Admin → Accounts → Features toggles
them off with no code change and full reversibility. Only a few items need route pruning.

---

## Tier 1 — Remove now (out of scope or irrelevant)

| Element | Why it is not needed | How to remove |
|---|---|---|
| **Captain** — 8 sidebar items (Overview, Responses, Documents, Scenarios, Playground, Inboxes, Tools, Settings) | AI is out of scope; see `ai-scope-decision.md`. The ТЗ mentions AI once, only to say it must not replace agent judgment | Flag `captain_tasks` off |
| **Calls** | Voice channel; absent from the ТЗ entirely | Flag `voice_recorder` off (`channel_voice` already off) |
| **Campaigns** | Proactive outbound messaging — a sales/marketing tool, not ticketing | Flag `campaigns` off |
| **Companies** | CRM company records. ТЗ 3.6 covers tagging of contacts and conversations only | Flag `crm` off |
| **Settings → Billing** | Chatwoot Cloud subscription management; meaningless on a self-hosted fork | Route prune (no flag exists) |

Effect: 5 nav entries, roughly 12 sidebar rows, from flags alone.

## Tier 2 — Enterprise-backed, non-functional without a licence

These render in the UI but their backends live in `enterprise/`. **If `enterprise/` is deleted,
they point at routes that return 500 at request time**, so pruning them is mandatory as part of
that decision rather than optional.

- **Settings → Audit logs**
- **Settings → Custom roles**
- **Settings → Conversation workflow** (`conversation_required_attributes`)
- **SAML** (under Security)
- **Settings → SLA** — ⚠️ special case. The SLA **frontend is MIT and fully reusable**: forms,
  timer components, reports, `useSlaStatus` composable. Keep the code and hide only the nav entry
  until the ТЗ 3.5 backend is built. Deleting it means rewriting it later for no benefit.

## Tier 3 — Channels, needs a decision

Currently enabled: `channel_facebook`, `channel_instagram`, `channel_tiktok`, website, email.
Also available in the codebase: WhatsApp, Telegram, Line, SMS, Twilio, Twitter.

**The ТЗ does not specify which channels Armeta supports.** Website widget and email are the
obvious keeps. Every other enabled channel adds clutter to the "Add Inbox" flow and a
configuration surface nobody maintains. Decision needed from the Support Department.

## Tier 4 — Integrations catalogue

`config/integration/apps.yml` ships: `webhooks`, `dashboard_apps`, `openai`, `linear`, `notion`,
`slack`, `dialogflow`, `google_translate`, `dyte`, `shopify`, `leadsquared`.

- **Keep `webhooks`** — this *is* the n8n mechanism for ТЗ 3.11
- **Keep `dashboard_apps`** — can embed an n8n-served panel inside the conversation sidebar
- **Drop `openai` and `dialogflow`** — AI, out of scope
- **The rest** depend on whether Armeta actually uses those tools

---

## Keep — maps directly to the ТЗ

| Element | ТЗ |
|---|---|
| Conversations, Folders / saved views | 3.2 |
| Reports | 3.3 |
| Agent panel, conversation view | 3.4 |
| Priority, snooze | 3.5 |
| Labels | 3.6 |
| Inboxes, Teams, Agents, Assignment policy | 3.7 |
| Help Center | 3.8 |
| Macros, Canned responses, Automation | 3.9 |
| Account switcher | 3.10 |
| **Agent bots** | 3.11 — the n8n integration mechanism |
| Contacts, Custom attributes, Profile, Security | supporting |

Custom attributes are worth keeping deliberately: a `custom_attribute_definition` becomes an
automation condition and a filter key with **zero code**.

## A bug to fix during the prune

`help_center` appears in the frontend `PREMIUM_FEATURES` array
(`app/javascript/dashboard/featureFlags.js`) but is **not** premium in `config/features.yml`,
where it is `enabled: true` by default. On some configurations this shows a paywall over a
feature that is actually free. Since ТЗ 3.8 requires the Help Center, remove it from that array.

## Suggested order

1. **Flags first.** Tier 1 is five toggles — no code, instantly reversible. Apply, screenshot the
   trimmed sidebar, show the lead.
2. **Confirm Tiers 3 and 4** with the analyst against real channel and tool usage.
3. **Code pruning last**, bundled with the `enterprise/` decision, since that decision forces the
   Tier 2 route removal regardless.

Removing UI is not the same as removing capability. Everything in Tier 1 can be switched back on
in seconds if the Support Department disagrees, so treat this list as a starting proposal.
