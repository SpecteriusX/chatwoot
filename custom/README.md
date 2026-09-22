# Armeta customization overlay

All Armeta-specific code lives here. Nothing in this directory is upstream Chatwoot code, and
nothing outside it should be edited to add Armeta behaviour.

## Why this exists

ТЗ 3.1 requires that Armeta changes go through official extension points, without editing core
files, so that upstream upgrades stay manageable. Chatwoot already supports exactly this: it is
the same mechanism Chatwoot Inc. uses to attach its own `enterprise/` code to the MIT core.

`lib/chatwoot_app.rb` resolves the overlay list:

```ruby
def self.extensions
  if custom?        then %w[enterprise custom]   # root.join('custom').exist?
  elsif enterprise? then %w[enterprise]
  else                   %w[]
  end
end
```

`config/initializers/01_inject_enterprise_edition_module.rb` walks that list, so a core class
calling `prepend_mod_with('Conversation')` resolves `Enterprise::Conversation` first, then
`Custom::Conversation`. Two consequences worth knowing:

- **`custom` is applied last, so `Custom::` wins** over the enterprise overlay for `prepend`.
- **Unresolved constants are a silent no-op.** If `Custom::Foo` does not exist, nothing happens
  and nothing raises. That also means a typo in a module name fails silently — verify with
  `Foo.ancestors` rather than assuming a module is active.

## Do not delete `custom/lib/custom.rb`

It defines `module Custom` and is load-bearing. There is a latent upstream bug in the injector:

```ruby
def const_get_maybe_false(mod, name)
  mod&.const_defined?(name, false) && mod&.const_get(name, false)
end
```

It returns **`false`** (not `nil`) for a missing constant, and `&.` only short-circuits on `nil`.
So once `custom/` exists, if the `Custom` constant is ever undefined, *every* `*_mod_with` call
site raises `NoMethodError: undefined method 'const_defined?' for false` and **the app will not
boot**. Chatwoot never hits this because `enterprise/` always defines `Enterprise`.

This is a real failure mode: it bites the moment the overlay is emptied out, e.g. after removing
the last file from `custom/app/models/custom/`. Keeping `custom/lib/custom.rb` makes the overlay
safe to leave empty.

## Layout

Mirrors `enterprise/`, because `config/application.rb` registers both trees the same way:

```
custom/
  app/{models,services,controllers,jobs,policies,listeners,builders,views}/
  lib/
  listeners/
  config/initializers/
```

Namespace everything under `Custom::`, matching the directory path:
`custom/app/models/custom/conversation.rb` → `Custom::Conversation`.

## How to override a core class

Core classes expose the seam themselves — there are 118 `*_mod_with` call sites across `app/`
and `lib/`. Check the bottom of the core file first:

```ruby
# app/models/conversation.rb (last line)
Conversation.prepend_mod_with('Conversation')
```

Then add the override:

```ruby
# custom/app/models/custom/conversation.rb
module Custom::Conversation
  def some_method
    # ... custom behaviour, then:
    super
  end
end
```

If a core class has no `*_mod_with` call, prefer adding one in a single isolated commit over
rewriting the class — a one-line addition is far cheaper to re-apply on an upstream bump than a
diverged file.

`enterprise/app/services/enterprise/action_service.rb` (12 lines, adds the `add_sla` automation
action) is the canonical worked example.

## Other extension seams worth preferring over an override

- **Automation actions** — add a method to an `ActionService` overlay and append the name to
  `AutomationRule#actions_attributes`. Dispatch is `send(action_name, params)`, so there is no
  dispatcher table to edit.
- **Filters / automation conditions** — `lib/filters/filter_keys.yml` is a data file driving both
  saved-filter search and automation conditions.
- **Custom attributes** — `custom_attribute_definitions` records become filter and automation
  conditions with zero code.
- **Event listeners** — subclass `BaseListener` and register via an `AsyncDispatcher` overlay
  instead of adding Conversation callbacks. Event names are in `lib/events/types.rb`.
- **Webhooks** — 12 account webhook events, HMAC-signed, for anything that can live outside the
  Rails process (this is the n8n path for ТЗ 3.11).

## Wiring

`config/application.rb` registers these paths. That edit is the single intentional change to a
core file in the whole overlay design; keep it in its own commit so it is trivial to re-apply
when rebasing onto a new upstream tag.
