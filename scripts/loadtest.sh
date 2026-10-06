#!/usr/bin/env bash
set -euo pipefail

host=${HOST:-inference.local}
port=${HTTP_PORT:-18080}
duration=${DURATION:-30}
concurrency=${CONCURRENCY:-30}
url="http://localhost:${port}/v1/generate"

out=$(mktemp -d)
end=$(( $(date +%s) + duration ))

worker() {
  while [ "$(date +%s)" -lt "$end" ]; do
    curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 -H "Host: ${host}" "$url" || true
  done > "$out/$1"
}

for i in $(seq "$concurrency"); do
  worker "$i" &
done
wait

total=$(cat "$out"/* | wc -l | tr -d ' ')
errors=$(cat "$out"/* | grep -cv '^2' || true)
rm -rf "$out"

echo "requests: ${total}  errors: ${errors}"
