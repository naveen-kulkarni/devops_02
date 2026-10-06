#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."

context=${CONTEXT:-k3d-${CLUSTER:-inference-lab}}
namespace=${NAMESPACE:-inference}
release=${RELEASE:-inference-api}
replicas=${REPLICAS:-3}
port=${HTTP_PORT:-18080}
chart=chart/inference-api
probe_image=busybox:1.37
reason=""

k() { kubectl --context "$context" "$@"; }
h() { helm --kube-context "$context" "$@"; }
fail() { reason=$1; }

fresh_namespace() {
  k delete namespace "$1" --ignore-not-found --wait=true >/dev/null 2>&1
  k create namespace "$1" >/dev/null
}

deploy_copy() {
  local ns=$1 host=$2
  shift 2
  fresh_namespace "$ns"
  k -n "$ns" apply -f deploy/postgres.yaml >/dev/null || return 1
  k -n "$ns" rollout status statefulset/postgres --timeout 180s >/dev/null || return 1
  h upgrade --install "$release" "$chart" -n "$ns" \
    --set replicaCount="$replicas" --set ingress.host="$host" "$@" >/dev/null 2>&1
}

request() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "Host: $1" "http://localhost:${port}/v1/generate"
}

wait_ok() {
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(request "$1")" = 200 ] && return 0
    sleep 2
  done
  return 1
}

probe() {
  local ns=$1 name=$2 labels=$3 script=$4
  k -n "$ns" run "$name" --image="$probe_image" --restart=Never --labels="$labels" \
    --command -- sh -c "$script" >/dev/null || return 1
  k -n "$ns" wait pod/"$name" --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null || return 1
  k -n "$ns" logs pod/"$name"
}

app_pods() {
  k -n "$1" get pods -l app.kubernetes.io/instance="$release" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{end}}{{end}}'
}

check_network() {
  local ns=verify-netpol outside=verify-outside host=netpol.verify.local
  local pod ip labels dns out

  deploy_copy "$ns" "$host" || { fail "release could not be deployed"; return; }
  wait_ok "$host" 90 || { fail "endpoint did not return 200 within 90s"; return; }

  pod=$(app_pods "$ns" | awk '{print $1}')
  ip=$(k -n "$ns" get pod "$pod" -o jsonpath='{.status.podIP}')
  labels=$(k -n "$ns" get pod "$pod" \
    -o go-template='{{range $k, $v := .metadata.labels}}{{if ne $k "pod-template-hash"}}{{$k}}={{$v}},{{end}}{{end}}')
  dns=$(k -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')

  fresh_namespace "$outside"
  out=$(probe "$outside" outside "run=probe" "
    nc -z -w 3 ingress-nginx-controller.ingress-nginx 80 && echo cluster
    nc -z -w 3 1.1.1.1 443 && echo internet
    nc -z -w 3 $ip 8080 && echo app
    true")
  case "$out" in *cluster*internet*) ;; *) fail "test pod has no network access"; return ;; esac
  case "$out" in *app*) fail "app accepts traffic from other namespaces"; return ;; esac

  out=$(probe "$ns" inside "${labels%,}" "
    nc -z -w 3 postgres 5432 && echo database
    nc -z -w 3 $dns 53 && echo dns-tcp
    nc -z -w 3 1.1.1.1 443 && echo internet
    true")
  case "$out" in *database*) ;; *) fail "app pod cannot reach the database"; return ;; esac
  case "$out" in *dns-tcp*) ;; *) fail "app pod cannot reach DNS over TCP"; return ;; esac
  case "$out" in *internet*) fail "app pod can reach external hosts"; return ;; esac
}

check_release() {
  local want live pod pf log local_port limit tmp a b

  want="inference-api-$(awk '/^version:/ {print $2}' "$chart/Chart.yaml")"
  live=$(h -n "$namespace" list --filter "^${release}\$" -o yaml | awk '/^ *chart:/ {print $2}')
  [ "$live" = "$want" ] || { fail "live release runs ${live:-nothing}, expected $want"; return; }
  h -n "$namespace" status "$release" 2>/dev/null | grep '^STATUS: deployed' >/dev/null ||
    { fail "live release is not in deployed state"; return; }

  for pod in $(app_pods "$namespace"); do
    log=$(mktemp)
    kubectl --context "$context" -n "$namespace" port-forward "pod/$pod" :8080 >"$log" 2>&1 &
    pf=$!
    sleep 2
    local_port=$(sed -n 's/.*127.0.0.1:\([0-9]*\).*/\1/p' "$log" | head -1)
    limit=$(curl -s -o /dev/null -D - --max-time 30 "http://127.0.0.1:${local_port}/v1/generate" |
      tr -d '\r' | awk -F': ' 'tolower($1) == "x-ratelimit-limit" {print $2}')
    kill "$pf" 2>/dev/null
    wait "$pf" 2>/dev/null
    rm -f "$log"
    [ "$limit" = 200 ] || { fail "responses advertise limit ${limit:-none}, expected 200"; return; }
  done

  tmp=$(mktemp -d)
  cp -R "$chart" "$tmp/"
  sed -i.orig -e 's/^version:.*/version: 9.9.9/' -e 's/^appVersion:.*/appVersion: "9.9.9"/' "$tmp/inference-api/Chart.yaml"
  a=$(h template "$release" "$chart" --show-only templates/deployment.yaml | awk '/^  selector:/ {s=1; print; next} s && /^  [^ ]/ {exit} s')
  b=$(h template "$release" "$tmp/inference-api" --show-only templates/deployment.yaml | awk '/^  selector:/ {s=1; print; next} s && /^  [^ ]/ {exit} s')
  rm -rf "$tmp"
  [ -n "$a" ] && [ "$a" = "$b" ] || { fail "deployment selector changes between chart versions"; return; }

  h template "$release" "$chart" --set app.config.rateLimit=300 | grep -A1 RATE_LIMIT | grep '300' >/dev/null ||
    { fail "rate limit setting is not applied"; return; }
  a=$(h template "$release" "$chart" --set app.config.rateLimit=300 --show-only templates/deployment.yaml | awk '/^  template:/ {s=1} s')
  b=$(h template "$release" "$chart" --set app.config.rateLimit=400 --show-only templates/deployment.yaml | awk '/^  template:/ {s=1} s')
  [ "$a" != "$b" ] || { fail "rate limit changes are not rolled out to pods"; return; }
}

check_rollout() {
  local ns=verify-rollout host=rollout.verify.local
  local dir i errors lowest grace delay

  deploy_copy "$ns" "$host" --set networkPolicy.enabled=false || { fail "release could not be deployed"; return; }
  k -n "$ns" rollout status deployment/"$release" --timeout 180s >/dev/null ||
    { fail "release did not become available"; return; }
  wait_ok "$host" 90 || { fail "endpoint did not return 200 within 90s"; return; }

  [ "$(k -n ingress-nginx get configmap ingress-nginx-controller -o jsonpath='{.data.proxy-next-upstream}')" = off ] ||
    { fail "ingress retries are enabled"; return; }
  k -n "$ns" get ingress -o yaml | grep proxy-next-upstream >/dev/null && { fail "ingress retries are enabled"; return; }

  dir=$(mktemp -d)
  for i in $(seq "${CONCURRENCY:-30}"); do
    (while [ ! -f "$dir/stop" ]; do request "$host"; echo; done > "$dir/load.$i") &
  done
  (while [ ! -f "$dir/rolled" ]; do
    k -n "$ns" get deployment "$release" -o jsonpath='{.status.availableReplicas}{"\n"}'
    sleep 1
  done > "$dir/available") &

  sleep 5
  for i in 1 2 3; do
    k -n "$ns" rollout restart deployment/"$release" >/dev/null
    k -n "$ns" rollout status deployment/"$release" --timeout 120s >/dev/null
  done
  touch "$dir/rolled"
  sleep 30
  touch "$dir/stop"
  wait

  errors=$(cat "$dir"/load.* | grep -cv '^2' | tr -d ' ')
  lowest=$(awk '{v = $1 == "" ? 0 : $1} NR == 1 || v < m {m = v} END {print m + 0}' "$dir/available")
  rm -rf "$dir"

  [ "$errors" -eq 0 ] || { fail "$errors failed requests during rollout"; return; }
  [ "$lowest" -ge "$replicas" ] || { fail "capacity dropped below $replicas replicas"; return; }

  grace=$(k -n "$ns" get deployment "$release" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
  delay=$(k -n "$ns" get deployment "$release" -o jsonpath='{.spec.template.spec.containers[0]..seconds}' | awk '{s += $1} END {print s + 0}')
  [ "${grace:-30}" -ge $(( delay + 20 )) ] || { fail "in-flight requests can be cut off during shutdown"; return; }
}

status=0
for n in ${*:-1 2 3}; do
  reason=""
  start=$(date +%s)
  case $n in
    1) check_network; k delete namespace verify-netpol verify-outside --ignore-not-found --wait=false >/dev/null 2>&1 ;;
    2) check_release ;;
    3) check_rollout; k delete namespace verify-rollout --ignore-not-found --wait=false >/dev/null 2>&1 ;;
    *) echo "unknown incident: $n"; status=1; continue ;;
  esac
  if [ -z "$reason" ]; then
    echo "incident $n: PASS ($(( $(date +%s) - start ))s)"
  else
    echo "incident $n: FAIL - $reason ($(( $(date +%s) - start ))s)"
    status=1
  fi
done
exit $status
