#!/usr/bin/env bash
#
# Runs the local demo stack from within java-example:
#   1. OPA server on :8181, loaded with the opa/initialised and opa/users bundles.
#      Decision logs are printed to this terminal (opa/config.yaml enables
#      decision_logs.console) so you can see the full JSON result OPA returned
#      for each query, alongside the input that produced it.
#   2. The Spring Boot app on :8080 (its /sites endpoint calls OPA to resolve
#      the caller's org, then looks up that org's sites).
#
# Requires: opa (https://www.openpolicyagent.org/docs/#running-opa) on PATH, JDK 21.
#
# Usage:
#   ./run.sh
#
# Ctrl-C stops both processes.

set -euo pipefail
cd "$(dirname "$0")"

echo "Starting OPA server on :8181 (opa/initialised, opa/users) ..."
opa run --server --addr :8181 -c opa/config.yaml opa/initialised opa/users &
OPA_PID=$!

cleanup() {
  echo
  echo "Stopping OPA (pid $OPA_PID) and Spring Boot (pid ${JAVA_PID:-})..."
  kill "$OPA_PID" "${JAVA_PID:-}" 2>/dev/null || true
  wait "$OPA_PID" "${JAVA_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Waiting for OPA to be ready ..."
until curl -sf http://localhost:8181/health >/dev/null 2>&1; do sleep 0.5; done
echo "OPA is up."

echo "Starting Spring Boot app on :8080 (first boot can take ~20-30s) ..."
./gradlew bootRun --console=plain &
JAVA_PID=$!

echo "Waiting for Spring Boot app to be ready ..."
until curl -sf "http://localhost:8080/sites?user=alice" >/dev/null 2>&1; do sleep 1; done
echo "Spring Boot app is up."

echo
echo "=== alice (known user, org acme-corp) ==="
curl -s "http://localhost:8080/sites?user=alice"; echo

echo "=== bob (known user, org globex) ==="
curl -s "http://localhost:8080/sites?user=bob"; echo

echo "=== carol (unknown user -> expect 403) ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://localhost:8080/sites?user=carol"

echo
echo "Stack is running (OPA :8181, Spring Boot :8080). Press Ctrl-C to stop."
wait
