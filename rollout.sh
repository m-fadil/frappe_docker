#!/bin/sh
# Zero-downtime deploy: rollout the request-facing services in order, then
# recreate the rest (queues/scheduler/configurator tolerate a brief restart).
#
#   ./rollout.sh .env.alphafitness
#
# Requires the `docker rollout` cli-plugin: https://github.com/Wowu/docker-rollout
set -eu

ENV_FILE=${1:?Usage: $0 <env-file>}

for service in backend websocket frontend; do
  docker rollout --env-file "$ENV_FILE" "$service" \
    --pre-stop-hook "touch /tmp/drain && sleep 10"
done

docker compose --env-file "$ENV_FILE" up -d --no-deps \
  configurator queue-short queue-long scheduler
