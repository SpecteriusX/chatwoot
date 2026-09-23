# Armeta fork — change and decision log

Running record of what changed and why, per session. Newest first.

Detailed working notes (orientation, verification, scope decisions) live outside the repo in
`~/Documents/armeta/`.

---

## 2026-09-23 — Security and robustness review

Authorised testing of authorization, input validation, injection and the unauthenticated public
surface. Full detail in `armeta-security-review.md`.

**No authorization or injection vulnerabilities found.** Cross-account access, privilege
escalation, unauthenticated access and IDOR all correctly rejected. Filter values are
parameterised — an injected value returned 0 rows rather than the full table.

**Six robustness defects fixed**, all malformed input reaching the model layer and raising 500
where `CLAUDE.md` requires a 422 at the controller boundary:

- `fix(filters): return 422 instead of 500 for malformed filter payloads`
- `fix(conversations): validate status and snoozed_until at the controller boundary`
- `fix(automation): return 422 instead of 500 for non-array conditions and actions`
- `fix(automation): validate event_name against supported events`

Notable causes: `AttachmentConcern` crashed at the *controller* layer before model validation
ever ran, so model guards alone were insufficient; and because Rails runs every validator,
guarding only the first `conditions` validator still crashed in the other three. An automation
rule with `event_name: "nope"` was found already in the database — created by an earlier test and
silently dead, which is what prompted adding `SUPPORTED_EVENT_NAMES`.

**Two findings reported rather than changed**, both needing a product decision and carrying
breakage risk if fixed carelessly:

- `widget/inbox_members` returns the full agent roster and live presence to anyone holding the
  public `website_token`. Upstream design; the widget needs it. A server-side filter is viable
  but `availability_status` combines the DB column with Redis presence, so it must be done with
  tests.
- An invalid `assignee_id` silently unassigns and returns 200, because `find_by` returns nil for
  both "not supplied" and "not found".

Also fixed during the session: `fix(super-admin): hide enterprise-only features when enterprise
is absent` — the settings page advertised six locked EE upsell cards, and account features could
still be toggled into a state whose backend no longer exists.

## 2026-09-23 — Enterprise removal

### Decisions

| Decision | Rationale |
|---|---|
| AI / Captain is out of scope | The ТЗ mentions AI once, only to constrain it (*«если появятся на последующих этапах»*). No AI block exists in 3.1–3.11. Captain is also enterprise-licensed, and the plan records that Enterprise is not being bought |
| `enterprise/` removed entirely | Verified first that nothing used it: 0 SLA policies, 0 custom roles, 0 assistants, 0 capacity policies, and every enterprise feature flag already `false`. Removal cost no working functionality |
| Enterprise code will not be copied or adapted | The enterprise licence covers modifications: *"Chatwoot… retain all right, title and interest in… all such modifications"*. ТЗ §5 says the same. SLA will be reimplemented clean-room from the spec |
| SLA frontend kept | Forms, timer components, reports and `useSlaStatus` are MIT and reusable against a future custom backend. Deleting them would mean rewriting them |
| Chatwoot Cloud rejected as hosting | Cannot run a customised fork. Noted as an internal contradiction in ТЗ 3.1, which recommends Cloud while also requiring a `prepend_mod_with` customisation layer |

### Changes

- `chore(custom): guard enterprise autoload paths on directory existence` — `config/application.rb`
- `chore(custom): remove proprietary enterprise directory` — 848 files, −66,559 lines
- `chore(custom): gate enterprise-only routes behind enterprise check` — `config/routes.rb`,
  `lib/chatwoot_app.rb`
- `fix(dashboard): honour feature flags on community installs` — `usePolicy.js`,
  `featureFlags.js`, two route files

### Findings

- **`ChatwootApp.extensions` was wrong for a custom-only fork.** It returned
  `%w[enterprise custom]` whenever `custom/` existed, regardless of whether `enterprise/` did.
  Combined with `const_get_maybe_false` returning `false` (and `&.` only guarding `nil`), deleting
  `enterprise/` would have crashed boot. Rewritten to reflect which directories actually exist.
- **`usePolicy.shouldShow` ignored feature flags on community installs** — it fell through to
  `return true`, so every premium nav item rendered against dead routes. Now returns
  `isFeatureFlagEnabled(flag)`. Side benefit: feature flags now genuinely control the sidebar.
- **`captain/tasks` is MIT, not enterprise.** It sits inside an otherwise-enterprise route
  namespace, so gating the whole namespace would have removed working agent-assist features
  (reply suggestion, summarise, rewrite, label suggestion). Gated the enterprise routes only.
- **`conversation_workflow` and `sla_reports` had no feature flag** in their route meta, so they
  survived the gating. Both now flagged.
- **`help_center` was listed in `PREMIUM_FEATURES`** but is not premium in `config/features.yml`,
  causing a paywall over a free feature required by ТЗ 3.8. Removed from that list.

### Fallback points

- Tag `pre-enterprise-removal` — state before any of this
- Each step is its own commit

---

## 2026-09-22 — Week 2: verification of out-of-the-box functionality

**ТЗ 3.6 (теггинг), 3.7 (маршрутизация), 3.9 (макросы/автоматизация) all pass.** No development
needed. Exercised through the public API and admin config, not by patching code.

- 3.6 — label created and edited via API, applied to a conversation *and* a contact, filterable
  in both, present in `summary_reports/label`
- 3.7 — 4 conversations distributed cleanly across 2 online agents (`john, agent2, john, agent2`);
  manual reassignment and policy editing both 200
- 3.9 — macro applied 3 actions; a keyword rule auto-tagged and re-prioritised with no human step

Findings worth carrying forward:

- **`assignment_v2` without an attached `AssignmentPolicy` silently disables auto-assignment.**
  `auto_assignment_v2_enabled?` checks only the account flag. No assignment, no error. This
  account was in that state
- **Round-robin only considers online agents** (`Inbox#available_agents` intersects with Redis
  presence). Out-of-hours traffic accumulates unassigned
- **An active Captain assistant blocked human auto-assignment** on its inbox —
  `should_run_auto_assignment?` bails when `assignee_agent_bot_id` is present
- **Clear `Sidekiq::RetrySet` / `DeadSet` after a version switch.** Jobs serialized against older
  code fail loudly on retry (730 log lines of a spurious enum error). Add to the upgrade runbook

ТЗ corrections raised: 3.5 overstates the Enterprise dependency (priority and snooze are both
MIT-native; only SLA is enterprise) · 3.2 saved views are per-user private with no sharing, so the
team-visibility criterion needs development · 3.8 the widget has no KB search at all · 3.3 reports
are complete but administrator-only.

---

## 2026-09-22 — Week 1: fork setup and customisation architecture

- Fork wired: `origin` = `SpecteriusX/chatwoot` (SSH), `upstream` = `chatwoot/chatwoot` with push
  disabled
- Branch `armeta/main` pinned to tag **v4.18.0** rather than the moving `develop`. The two are
  divergent (26 ahead / 15 behind), so pinning makes the base reproducible and upstream syncs
  deliberate tag-to-tag bumps
- **`custom/` overlay created** — satisfies ТЗ 3.1 *«Архитектура кастомизаций»*. Armeta code
  attaches via `prepend_mod_with` with one intentional core edit (`config/application.rb`),
  isolated in its own commit for easy rebasing
- Legal boundary mapped: of 13 features checked, only 4 are enterprise-only — SLA, Captain,
  custom roles, audit logs

Findings:

- **`custom/lib/custom.rb` is load-bearing.** If `custom/` exists but the `Custom` constant does
  not, every `*_mod_with` call site raises `NoMethodError` and the app will not boot
- Local Docker hosting and the personal fork are bridging states until Armeta resources are
  granted; nothing hardcodes `localhost` and the fork URL lives only in git remote config
