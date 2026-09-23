# Runbook — running and deploying this fork

Practical reference for the Armeta Chatwoot fork. Command-first.

---

## Part 1 — Docker in 15 commands

Docker runs each service in its own **container** from an **image** (a template). Compose starts
several containers together from `docker-compose.yaml`. Data that must survive a container being
replaced lives in a **volume**.

```bash
docker compose ps                 # what is running, and on which ports
docker compose up -d              # start everything in the background
docker compose down               # stop and remove containers (volumes survive)
docker compose restart rails      # restart one service
docker compose stop               # stop without removing

docker compose logs -f rails      # follow logs for one service
docker compose logs --tail 50 sidekiq
docker compose logs --since 5m rails

docker compose exec rails bash    # shell inside a running container
docker compose exec -T rails <cmd>          # run one command, no TTY (for scripts)
docker compose run --rm rails <cmd>         # throwaway container, for one-off tasks

docker compose build base         # rebuild an image after Gemfile/Dockerfile changes
docker compose up -d --force-recreate rails # recreate a container after config changes

docker stats --no-stream          # CPU/memory per container
docker system df                  # disk used by images, containers, volumes
```

**The two distinctions that matter:**

- `exec` runs inside an **already-running** container. `run` starts a **new temporary** one —
  use it when the app container is down or for one-off tasks like migrations.
- `down` removes containers but **keeps volumes**. `down -v` **deletes the volumes too**, which
  means deleting the database. Never type `-v` on anything you care about.

**Changes that need more than a restart:**

| Changed | Needed |
|---|---|
| Ruby/Vue source | nothing — bind-mounted, picked up live |
| `.env`, `docker-compose*.yml` | `docker compose up -d --force-recreate <svc>` |
| `config/*.rb` (application.rb, routes.rb) | `docker compose restart rails` |
| `Gemfile`, `Dockerfile` | `docker compose build base` then rails/vite, then `up -d` |

---

## Part 2 — Local development

### Daily

```bash
cd ~/armeta/chatwoot/chatwoot
docker compose up -d
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/app/login   # expect 200
```

Dashboard http://localhost:3000 · Mailhog http://localhost:8025 · Postgres `localhost:5432`

Login `john@acme.inc` / `Password1!`

⚠️ **Vite reinstalls packages on every start** (its entrypoint runs `pnpm install --force`), so
assets take roughly 40–60s to become available after `up`. Not a fault — just wait for
`/vite-dev/@vite/client` to return 200.

### Common tasks

```bash
# Rails console
docker compose exec rails bundle exec rails c

# one-off script
docker compose exec -T rails bundle exec rails runner 'puts Conversation.count'

# database shell  (note: chatwoot_dev, NOT chatwoot)
docker compose exec postgres psql -U postgres -d chatwoot_dev

# migrations
docker compose exec rails bundle exec rails db:migrate
docker compose exec rails bundle exec rails db:migrate:status

# lint before committing (host has no node_modules, so run them in containers)
docker compose exec -T rails bundle exec rubocop --force-exclusion <files>
docker compose exec -T vite npx eslint <files>
```

### Full reset (destroys all local data)

```bash
docker compose down
docker volume rm chatwoot_postgres chatwoot_redis
docker compose up -d postgres redis
docker compose run --rm rails bundle exec rails db:chatwoot_prepare
docker compose up -d
```

---

## Part 3 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Postgres restart loop, *"superuser password is not specified"* | `POSTGRES_PASSWORD` is empty in the upstream compose | `POSTGRES_HOST_AUTH_METHOD=trust` — already in `docker-compose.override.yml` |
| Database empty after recreating the container | Upstream mounts the volume at `/data/postgres`, but the image writes to `/var/lib/postgresql/data` | `PGDATA=/data/postgres/pgdata` — already in the override |
| Assets 404, Rails tries to build Vite itself and runs out of memory | Vite bound `::1` only. Upstream sets `VITE_DEV_SERVER_HOST`, which nothing reads | `VITE_RUBY_HOST` — already in the override |
| Sidekiq floods logs with errors after a version change | Jobs serialized against the old code failing on retry | Clear the queues (below) |
| Laptop lags badly while Docker runs | Docker Desktop VM over-allocated | `~/.docker/desktop/settings-store.json` → `Cpus: 4`, `MemoryMiB: 4096` |
| `git commit` fails on `lint-staged` | Host has no `node_modules` | `pnpm install` on the host, or `--no-verify` after linting in-container |

**Clear stuck Sidekiq jobs** — do this after every upstream version bump:

```bash
docker compose exec -T rails bundle exec rails runner '
require "sidekiq/api"
Sidekiq::RetrySet.new.clear; Sidekiq::DeadSet.new.clear'
```

`docker-compose.override.yml` carries the three upstream fixes above. It is **auto-loaded** by
compose and hidden from git via `.git/info/exclude`, so `git status` stays clean.

---

## Part 4 — Deploying to a server

### The thing that catches people first

`docker-compose.production.yaml` uses `image: chatwoot/chatwoot:latest` — **upstream's image, not
yours**. It contains none of the Armeta changes. You must build and publish your own:

```bash
docker build -t registry.example.com/armeta/chatwoot:$(cat VERSION_CW) -f docker/Dockerfile .
docker push  registry.example.com/armeta/chatwoot:$(cat VERSION_CW)
```

Then point the `image:` line at your tag. **Tag by version, never deploy `:latest`** — you cannot
roll back to a tag that keeps moving.

### What the server needs

Rails · Sidekiq · PostgreSQL **with pgvector** · Redis · SMTP · object storage · a reverse proxy
for TLS. Minimum realistically 4 GB RAM.

### Environment

Copy `.env.example` → `.env` and set at least:

```bash
RAILS_ENV=production
SECRET_KEY_BASE=<openssl rand -hex 64>     # alphanumeric only
FRONTEND_URL=https://support.armeta.example
FORCE_SSL=true

POSTGRES_HOST=postgres
POSTGRES_USERNAME=postgres
POSTGRES_PASSWORD=<set this — empty will not boot>
REDIS_URL=redis://redis:6379
REDIS_PASSWORD=<set this>

SMTP_ADDRESS=...            SMTP_PORT=587
SMTP_USERNAME=...           SMTP_PASSWORD=...
MAILER_SENDER_EMAIL=Armeta Support <support@armeta.example>

ACTIVE_STORAGE_SERVICE=s3   # local storage does not survive container replacement
S3_BUCKET_NAME=...  AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_REGION=...
```

⚠️ Production compose ships `POSTGRES_PASSWORD=` **empty**, exactly like dev. Set it or Postgres
refuses to start.

⚠️ `ACTIVE_STORAGE_SERVICE=local` puts attachments on the container filesystem. Replace the
container and every customer attachment is gone. Use S3 or an S3-compatible bucket.

### First deploy

```bash
docker compose -f docker-compose.production.yaml run --rm rails \
  bundle exec rails db:chatwoot_prepare
docker compose -f docker-compose.production.yaml up -d
```

### Subsequent deploys

```bash
git pull && docker build -t <registry>/armeta/chatwoot:<new-version> -f docker/Dockerfile .
docker push <registry>/armeta/chatwoot:<new-version>
# update image tag, then:
docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:migrate
docker compose -f docker-compose.production.yaml up -d
```

Migrations run **before** the new containers start. Rollback = point the tag back and `up -d`,
which is why immutable version tags matter.

### TLS

Terminate TLS at a reverse proxy (Caddy is the least effort; nginx + certbot works too) and
forward to `rails:3000`. Chatwoot uses **WebSockets** for live updates, so the proxy must forward
`Upgrade` and `Connection` headers or the dashboard will silently stop updating in real time.

### Before going live

- [ ] Own image built and pushed, tagged by version
- [ ] `POSTGRES_PASSWORD` and `REDIS_PASSWORD` set
- [ ] `SECRET_KEY_BASE` generated fresh — never reuse the dev value
- [ ] `FRONTEND_URL` matches the real domain, `FORCE_SSL=true`
- [ ] S3 configured for attachments
- [ ] **Database backups configured and a restore actually tested**
- [ ] SMTP verified with a real send
- [ ] Postgres port **not** publicly exposed
- [ ] Captain / AI left disabled (enterprise licence — see `armeta-log.md`)

The backup line is the one that matters most. An untested backup is not a backup.

### Upgrading from upstream

```bash
git fetch upstream --tags
git rebase v4.19.0            # replays the Armeta commits onto the new tag
```

Rebase rather than merge: the fork is a thin layer over upstream, so replaying the Armeta commits
produces fewer conflicts than merging. Expect conflicts where upstream touched files we deleted
(`enterprise/`) or edited (`config/application.rb`, `config/routes.rb`). Then clear the Sidekiq
queues, as above.
