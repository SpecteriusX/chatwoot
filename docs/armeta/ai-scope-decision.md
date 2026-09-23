# AI / Captain — scope decision

**Decision: customer-facing AI is out of scope. The Captain sandbox has been removed from the
instance. 2026-09-23.**

## Why

**1. The ТЗ does not require it.** There is exactly one mention of AI in the whole document,
in the §3 preamble:

> «Ассистентские/AI-функции **(если появятся на последующих этапах)** не заменяют решение
> агента — окончательное решение по обращению клиента остаётся за агентом/экспертом поддержки.»

That is a constraint on hypothetical future AI, not a requirement for it. None of the eleven
functional blocks (3.1–3.11) is an AI block, and §1's summary list does not include one.
ТЗ 3.11 mentions «конструктор сценариев **бота**», but that is n8n flow logic, not an LLM.

Captain was present because Chatwoot ships it, and was enabled during Week 1 exploration to
answer a question about model selection. It was never an Armeta requirement.

**2. Licensing.** Captain Assistants live entirely under `enterprise/`, whose licence permits
copying for development and testing but forbids production use without a paid subscription. The
priorities plan records the decision *«Enterprise-лицензию не покупаем»*. Shipping Captain as
things stand would breach that licence.

**3. Sequencing — the strongest practical reason.** Captain answers from a knowledge base via
vector search. ТЗ 3.8 content has not been collected yet. Against an empty knowledge base every
conversation ends in `missing_knowledge`, hands off to a human anyway, and adds latency and cost
for no deflection. The Week 1 demo only worked because a FAQ entry was hand-seeded.

The correct order is knowledge base first, AI on top of it later — the KB is in scope, useful on
its own as a public Help Center, and is the prerequisite for any AI that follows.

## What was removed

Database state only — no application code was touched, so this does not pre-empt the open
`enterprise/` decision.

- `captain_integration` and `captain_integration_v2` disabled on account 1
- Test assistant «Acme Helper», its FAQ entry and its `CaptainInbox` link destroyed
- `assignee_agent_bot_id` / `ai_assignee_type` cleared from all conversations

Verified after: `Inbox#captain_active?` is `false`, `active_bot?` is `false`, app healthy
(login / assets / auth all 200).

Side effect worth noting: inbox 1's auto-assignment now works again. `should_run_auto_assignment?`
returns false whenever `assignee_agent_bot_id` is present, so an active assistant was silently
preventing round-robin on that inbox (see `week2-verification.md`, finding 3).

## What was deliberately kept

**The OpenAI API key** in `installation_configs`. It is still used by MIT agent-assist (below),
and removing it only means re-pasting later.

**The `captain_tasks` feature flag**, which is MIT and enabled by default.

## The distinction that matters if this is revisited

Not all of Captain is Enterprise:

| | Licence | What it does |
|---|---|---|
| **Captain Assistants** — customer-facing bot, RAG, handoff | `enterprise/` | Replaces first-line support |
| **Captain Tasks** — reply suggestion, summarise, rewrite, label suggestion | **MIT core** | Assists the agent |

`app/controllers/api/v1/accounts/captain/tasks_controller.rb` is in `app/`, not `enterprise/`,
with no enterprise route gate, backed by the MIT services in `lib/captain/`.

So **agent-assist AI is available today at no licence cost**, and fits the ТЗ's stated philosophy
better than a bot: the agent keeps the final decision and the AI only saves typing. It also needs
no knowledge base to be useful. This is the option to reach for first if an AI capability is
wanted before the KB exists.

## Preconditions for revisiting customer-facing AI

1. ТЗ 3.8 knowledge base populated with real article content
2. Two to three months of ticket data showing which questions actually repeat
3. A licence decision: buy Enterprise, or build RAG in MIT space
4. A scope change agreed via ТЗ 2.5, since 2.4 fixes the boundary at 3.1–3.11

## How to re-enable the sandbox

```ruby
account = Account.find(1)
account.enable_features!('captain_integration')
assistant = Captain::Assistant.create!(
  account: account, name: 'Acme Helper',
  config: { 'product_name' => 'Acme', 'feature_faq' => true, 'temperature' => 1 }
)
CaptainInbox.create!(captain_assistant: assistant, inbox: account.inboxes.first)
Captain::AssistantResponse.create!(
  account: account, assistant: assistant,
  question: 'What are your support hours?',
  answer: 'Acme Support is available Monday to Friday, 9am to 6pm IST.'
)
```

The API key is already configured. Embeddings generate asynchronously via Sidekiq
(`Captain::Llm::UpdateEmbeddingJob`), 1536 dimensions, usually within ~15 seconds.

⚠️ For development and testing only. Must remain disabled on any production deployment unless an
Enterprise subscription is purchased.
