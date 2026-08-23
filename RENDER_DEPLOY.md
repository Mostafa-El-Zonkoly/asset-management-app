# Deploying the Portfolio App on Render

This is a Render-ready copy of the portfolio app. It deploys as a **Docker web
service backed by managed PostgreSQL**. There is **no Redis and no Sidekiq
worker** — background jobs run in-process with the `:async` Active Job adapter.

## What changed vs. the original project

| File | Change |
|---|---|
| `render.yaml` | **New.** Render Blueprint: Docker web service + PostgreSQL. |
| `Dockerfile` | Now targets **production** (`RAILS_ENV=production`, `BUNDLE_WITHOUT=development:test`); removed the hardcoded local DB credentials; serves static assets; boots via Puma on Render's `$PORT`. |
| `bin/docker-entrypoint` | Runs `db:prepare` (create + migrate + seed) on every boot; add `SKIP_DB_PREPARE=1` to skip. |
| `.dockerignore` | **New.** Keeps logs, tmp, secrets, and `.git` out of the image. |
| `config/environments/production.rb` | Active Job adapter → `:async`; `assume_ssl`; health check `/up` excluded from the HTTPS redirect; static files served when `RAILS_SERVE_STATIC_FILES` is set. |
| `config/cable.yml` | Production Action Cable adapter → `async` (was `redis`). |
| `config/initializers/sidekiq.rb` | No-op unless `REDIS_URL` is set, so the app boots without Redis. |

Nothing else in the app was modified. Devise signs with a hardcoded secret and
the app does not read encrypted credentials at runtime, so **no
`RAILS_MASTER_KEY` is required**.

## Deploy steps

1. **Push this folder to a Git repo** (GitHub/GitLab), e.g.:
   ```bash
   cd portfolio-app-render
   git init && git add -A && git commit -m "Render-ready portfolio app"
   git remote add origin <your-repo-url>
   git push -u origin main
   ```
2. In the **Render dashboard** → **New** → **Blueprint**, connect the repo.
   Render reads `render.yaml` and creates the database + web service.
3. Click **Apply**. The first deploy builds the Docker image, provisions
   PostgreSQL, wires `DATABASE_URL`, generates `SECRET_KEY_BASE`, then boots.
   `db:prepare` loads the schema and runs `db/seeds.rb` on first boot.
4. Open the service URL. Log in / sign up via Devise.

You can also deploy without the Blueprint: create a **Web Service** from the
repo (Runtime: Docker), add a **PostgreSQL** instance, and set the env vars
listed in `render.yaml` manually.

## Environment variables

| Variable | Set by | Notes |
|---|---|---|
| `DATABASE_URL` | Blueprint (from the DB) | PostgreSQL connection string. |
| `SECRET_KEY_BASE` | Blueprint (`generateValue`) | Signs sessions/cookies. |
| `RAILS_ENV` | `production` | |
| `RAILS_SERVE_STATIC_FILES` | `true` | Rails serves compiled assets (no NGINX). |
| `RAILS_LOG_TO_STDOUT` | `true` | Logs go to Render's log stream. |
| `RAILS_MAX_THREADS` | `3` | Puma threads = DB pool size. |
| `RAILS_MASTER_KEY` | *(optional)* | Only if you start reading encrypted credentials. |

## Notes & limitations

- **Free tier:** the free web service sleeps after ~15 min idle (cold start on
  next request), and the free PostgreSQL expires ~30 days after creation.
  Upgrade the plans in `render.yaml` (`starter` web, `basic-256mb`+ DB) to keep
  it always-on and permanent.
- **File uploads:** `config.active_storage.service = :local`. Render's disk is
  ephemeral, so locally-stored uploads are lost on redeploy. Attach a Render
  **Disk**, or switch Active Storage to an S3-compatible bucket, if you need
  persistent uploads.
- **Scheduled jobs are off.** The daily price-fetch and portfolio-snapshot cron
  jobs need Sidekiq + Redis, which are not provisioned here. You can still run
  them manually from a Render Shell:
  ```bash
  ./bin/rails runner "PriceFetchJob.perform_now"
  ./bin/rails runner "PortfolioSnapshotJob.perform_now"
  ```
  Or use Render **Cron Jobs** to run those commands on a schedule.

## Re-enabling Sidekiq + Redis later

1. Add a **Key Value (Redis)** instance in `render.yaml` and a `worker` service
   running `bundle exec sidekiq -C config/sidekiq.yml`.
2. Set `REDIS_URL` on both the web and worker services (the initializer and
   Action Cable pick it up automatically).
3. Change `config.active_job.queue_adapter` back to `:sidekiq` in
   `config/environments/production.rb`, and set `config/cable.yml` production
   adapter back to `redis`.
