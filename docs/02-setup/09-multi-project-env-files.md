---
title: Multi-Project Env Files
---

# Running Multiple Projects with Per-Project Env Files

The setup examples pass every override on the command line and keep settings in a single
`.env`:

```sh
docker compose -p erpnext-one \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.https.yaml \
  up -d
```

That works, but it does not scale past one bench on a server. The override list has to be
retyped (or copy-pasted from a note) on every command, and the shared `.env` can only describe
one project at a time.

Compose can read both the override list and the project name from an env file, so each project
gets one self-contained file and every command becomes short. No wrapper script, no Makefile.

## 1. Create an env file per project

Keep the files outside the repository so they can be tracked in your own private config repo,
for example in `~/gitops`:

```sh
mkdir -p ~/gitops
cp example.env ~/gitops/.env.erpnext-one
```

Add two variables at the top of `~/gitops/.env.erpnext-one`:

```sh
COMPOSE_PROJECT_NAME=erpnext-one
COMPOSE_FILE=/home/ubuntu/frappe_docker/compose.yaml:/home/ubuntu/frappe_docker/overrides/compose.mariadb.yaml:/home/ubuntu/frappe_docker/overrides/compose.redis.yaml:/home/ubuntu/frappe_docker/overrides/compose.https.yaml:/home/ubuntu/frappe_docker/overrides/compose.migrator.yaml
```

`COMPOSE_FILE` is a `:`-separated list, in merge order, exactly like repeated `-f` flags.
Use **absolute paths** — see [Path resolution](#path-resolution) below.

Then set the rest of the values for this project as usual: `CUSTOM_IMAGE`, `CUSTOM_TAG`,
`DB_PASSWORD`, `SITES_RULE`, `LETSENCRYPT_EMAIL`, and so on. See
[environment variables](04-env-variables.md).

Repeat for the next bench:

```sh
cp ~/gitops/.env.erpnext-one ~/gitops/.env.erpnext-two
```

and edit `COMPOSE_PROJECT_NAME`, `SITES_RULE`, and the ports or database settings that must
differ.

## 2. Verify the merge

Before starting anything, confirm that Compose picks up the file list and the project name:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one config
```

The output is the fully merged and interpolated stack. If it contains the services from every
override you listed, the env file is being read correctly.

> **Note:** `--env-file` is a flag of `docker compose` itself, so it goes **before** the
> subcommand. `docker compose config --env-file ...` is not the same thing.

## 3. Run the project

Every command follows the same shape:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one up -d
docker compose --env-file ~/gitops/.env.erpnext-one ps
docker compose --env-file ~/gitops/.env.erpnext-one logs -f backend
docker compose --env-file ~/gitops/.env.erpnext-one down
```

Site creation and other bench commands work the same way:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one \
  exec backend bench new-site one.example.com \
  --mariadb-user-host-login-scope='172.%.%.%' \
  --install-app erpnext
```

The second bench is the same commands with a different env file:

```sh
docker compose --env-file ~/gitops/.env.erpnext-two up -d
```

If typing the path gets tedious, a shell alias per project is enough:

```sh
alias dc1='docker compose --env-file ~/gitops/.env.erpnext-one'
alias dc2='docker compose --env-file ~/gitops/.env.erpnext-two'

dc1 up -d
dc2 logs -f backend
```

## Updating a project

Changing the image tag is now a one-line edit in the project's env file:

```sh
# ~/gitops/.env.erpnext-one
CUSTOM_TAG=v1.4.0
```

Pull first so the download does not count as downtime, then recreate:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one pull
docker compose --env-file ~/gitops/.env.erpnext-one up -d
```

Only the containers whose image changed are recreated.

## Migrations

If you included `overrides/compose.migrator.yaml`, `bench --site all migrate` runs whenever the
`migrator` container is started — which includes every `docker compose up -d`, not only the ones
that change the image. Each run puts sites into maintenance mode for its duration, so on a busy
stack it is usually better to keep it off by default:

```sh
# ~/gitops/.env.erpnext-one
MIGRATE_SITES=false
```

and enable it explicitly as a deploy step:

```sh
MIGRATE_SITES=true docker compose --env-file ~/gitops/.env.erpnext-one \
  up -d --force-recreate migrator
docker compose --env-file ~/gitops/.env.erpnext-one logs migrator
```

The `migrator` service retries on failure and then stays exited, while the rest of the stack
keeps serving traffic either way — so check its logs instead of assuming the migration
succeeded.

Without the override, run the migration by hand after an update:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one \
  exec backend bench --site all migrate
```

## Cloning a site from a remote instance

`overrides/compose.restore.yaml` pulls the latest database backup from another Frappe site,
restores it into a local site and migrates it — useful for refreshing a staging bench from
production. Add it to the project's `COMPOSE_FILE`, then set:

```sh
# ~/gitops/.env.erpnext-one
RESTORE_SITE=staging.example.com
RESTORE_SOURCE_URL=https://erp.example.com
RESTORE_TOKEN=<api_key>:<api_secret>
```

The target site must already exist locally. Run it explicitly — the service is behind the
`restore` profile, so `up -d` never triggers it:

```sh
docker compose --env-file ~/gitops/.env.erpnext-one \
  --profile restore run --rm restore
```

It calls `frappe.utils.backups.fetch_latest_backups` on the source site, downloads the database
dump it points to, runs `bench restore --force`, then `bench migrate`.

> **Warning:** This drops the target site's database. Never point `RESTORE_SITE` at a production
> site. The token needs read access to the source site's private backups, so treat the env file
> as a credential.

Two things it does not do: it never asks the source site to take a fresh backup, so you get
whatever backup exists there (schedule one with `compose.backup-cron.yaml` on the source, or
run `bench --site ... backup` before restoring); and it restores the database only, not public
or private files.

## Path resolution

Relative paths in `COMPOSE_FILE` are resolved against the directory you run the command from,
not against the location of the env file. Absolute paths make the commands work from anywhere,
which is what you want for cron jobs and CI runners:

```sh
COMPOSE_FILE=/home/ubuntu/frappe_docker/compose.yaml:/home/ubuntu/frappe_docker/overrides/compose.proxy.yaml
```

If any path contains a `:`, change the separator:

```sh
COMPOSE_PATH_SEPARATOR=,
COMPOSE_FILE=/path/one.yaml,/path/two.yaml
```

## Notes and limitations

- `--env-file` replaces the default `.env`, it is not merged with it. Each project file must be
  complete on its own — which is the point, but it is why `cp example.env` is the right way to
  start one.
- Values are used for interpolation in the compose files. They are not injected into containers
  unless a service maps them in its `environment:` block.
- These files hold database and Let's Encrypt settings. Keep the directory private
  (`chmod 700 ~/gitops`) and out of any public repository.
- This approach keeps the overrides as separate, diffable files and re-reads the env file on
  every command. If you instead need one portable, fully-resolved YAML artifact for a GitOps or
  CI pipeline, keep using `docker compose config > docker-compose.yml` as shown in
  [setup examples](06-setup-examples.md) — but note that env values are baked into that output,
  so `MIGRATE_SITES=true docker compose ...` has no effect on it.

---

**Back:** [Single Server Example (nginx-proxy)](08-single-server-nginxproxy-example.md)
