#!/bin/sh
# Zero-downtime deploy: rollout the request-facing services in order, then
# recreate the rest (queues/scheduler/configurator tolerate a brief restart).
#
#   ./rollout.sh .env.alphafitness
#
# Requires the `docker rollout` cli-plugin: https://github.com/Wowu/docker-rollout
set -eu

ENV_FILE=${1:?Usage: $0 <env-file>}

# Drop the cached asset manifest BEFORE any new container starts, so they read
# the new build's hashes off disk instead of inheriting the old ones.
#
# Two reasons this has to be done by hand, and done first:
#  - `bench clear-cache` misses it: the key is written shared (plain
#    `assets_json`) but cleared unshared (`<db_name>|assets_json`).
#  - Each gunicorn worker also keeps it in process memory for 10 minutes
#    (ClientCache.local_ttl), so deleting it after a container has already read
#    the stale value only takes effect on the next restart.
docker compose --env-file "$ENV_FILE" exec -T redis-cache redis-cli DEL assets_json

for service in frontend backend websocket; do
  docker rollout --env-file "$ENV_FILE" "$service" \
    --pre-stop-hook "touch /tmp/drain && sleep 10"
done

docker compose --env-file "$ENV_FILE" up -d --no-deps \
  configurator queue-short queue-long scheduler

docker compose --env-file "$ENV_FILE" exec -T backend bench --site all clear-cache
