#!/usr/bin/env bash
# Validates compose.yaml for every storage x TLS combination with a sample
# environment (no containers are started). Used by CI and locally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE="$ROOT/tests/sample.env"
fail=0
for storage in fs s3; do
    for tls in local cloud; do
        profiles=()
        [[ $storage == s3 ]] && profiles+=(s3)
        [[ $tls == cloud ]] && profiles+=(cloud)
        joined=$(IFS=,; echo "${profiles[*]}")
        services=$(COMPOSE_PROFILES="$joined" PNEX_TLS_MODE="$tls" \
            docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" \
            --env-file "$SAMPLE" config --services 2>&1) || {
            echo "FAIL storage=$storage tls=$tls"
            echo "$services"
            fail=1
            continue
        }
        echo "OK   storage=$storage tls=$tls: $(echo "$services" | sort | tr '\n' ' ')"
    done
done
exit $fail
