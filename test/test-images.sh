#!/usr/bin/env bash
# Run the TAP suite against each built container image in CONNECT mode.
#
# For every distro the script stands up a FRESH MySQL (so no GTID state
# leaks between distros), runs the product image as an external reader in
# two flavors, and points the test binaries at it:
#
#   batching flavor (-b 1 -t 300) -> the batched tests
#   normal   flavor (-b 0 -t 0)   -> the remaining tests
#
# Inputs (env, with defaults):
#   IMAGE_PREFIX   image repo to test          (proxysql/proxysql-mysqlbinlog)
#   DISTROS        space-separated distro tags  (all six)
#   MYSQL_VERSION  dbdeployer version token     (84); the port is derived
#   RUNNER_IMG     image carrying the libs to run the *-t binaries
#
# Exit status is non-zero if any test failed.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
INFRA_DIR="$REPO/test/infra"

IMAGE_PREFIX=${IMAGE_PREFIX:-proxysql/proxysql-mysqlbinlog}
DISTROS=${DISTROS:-"centos9 centos10 debian12 debian13 ubuntu22 ubuntu24"}
MYSQL_VERSION=${MYSQL_VERSION:-84}
RUNNER_IMG=${RUNNER_IMG:-proxysql/proxysql-mysqlbinlog:build-ubuntu24}

# Version -> MySQL port table (mirrors test/tap/run.sh).
port_for() {
  case "$1" in
    57) echo 3357 ;;
    80) echo 3380 ;;
    84) echo 3384 ;;
    90) echo 3390 ;;
    94) echo 3394 ;;
    *)  echo "unknown MYSQL_VERSION token: $1" >&2; return 1 ;;
  esac
}
MYSQL_PORT=$(port_for "$MYSQL_VERSION") || exit 1

NORMAL_TESTS="test_basic_startup-t test_basic_updates-t test_connect_disconnect-t \
              test_consecutive_writes-t test_multi_client-t test_sparse_intervals-t"
BATCH_TESTS="test_batched_updates-t"

NET=""
rc=0

# Run one *-t binary in connect mode against the reader at IP $1.
run_test() { # $1=reader_ip  $2=test  $3=label
  echo "::group::[$3] $2"
  if docker run --rm --network "$NET" \
       -v "$REPO":/opt/proxysql_mysqlbinlog -w /opt/proxysql_mysqlbinlog \
       -e MYSQL_HOST=mysql -e MYSQL_PORT="$MYSQL_PORT" -e MYSQL_USER=root \
       -e MYSQL_PASSWORD=root -e MYSQL_VERSION="$MYSQL_VERSION" \
       -e BINLOG_READER_BIN= -e BINLOG_READER_HOST="$1" -e BINLOG_READER_PORT=6020 \
       "$RUNNER_IMG" ./test/tap/tests/"$2"; then
    echo "RESULT $3/$2: PASS"
  else
    echo "RESULT $3/$2: FAIL"; rc=1
  fi
  echo "::endgroup::"
}

# Start the product image as a reader; echo its container IP on the infra net.
# The client connects by IPv4 only (inet_pton, no DNS), hence the IP.
start_reader() { # $1=image  $2=batching  $3=freq_ms
  docker rm -f reader >/dev/null 2>&1 || true
  docker run -d --name reader --network "$NET" \
    -e MYSQL_HOST=mysql -e MYSQL_PORT="$MYSQL_PORT" -e MYSQL_USER=root \
    -e MYSQL_PASSWORD=root -e BATCHING="$2" -e UPDATE_FREQ_MS="$3" -e LISTEN_PORT=6020 \
    "$1" >/dev/null
  sleep 4
  # Surface why the reader died (e.g. auth failures) — to stderr so it does
  # not pollute the IP captured by the caller.
  if [ "$(docker inspect -f '{{.State.Status}}' reader 2>/dev/null)" != running ]; then
    echo "reader container is not running; logs:" >&2
    docker logs reader >&2 2>&1 || true
  fi
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' reader
}

# Recreate a clean MySQL and set NET to its docker network.
fresh_infra() {
  ( cd "$INFRA_DIR" && docker compose down -v >/dev/null 2>&1 || true )
  ( cd "$INFRA_DIR" && MYSQL_VERSIONS="$MYSQL_VERSION" docker compose up -d mysql )
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' binlog-reader-infra 2>/dev/null)" = healthy ] && break
    sleep 5
  done
  # let MySQL settle after it reports healthy
  sleep 10
  NET=$(docker inspect binlog-reader-infra \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')
}

for distro in $DISTROS; do
  echo "================ DISTRO=$distro ================"
  img="${IMAGE_PREFIX}:${distro}"
  fresh_infra

  # Batching flavor first (cleanest GTID state), then the normal flavor.
  ip=$(start_reader "$img" 1 300)
  for t in $BATCH_TESTS; do run_test "$ip" "$t" "$distro-batching"; done
  docker rm -f reader >/dev/null 2>&1 || true

  ip=$(start_reader "$img" 0 0)
  for t in $NORMAL_TESTS; do run_test "$ip" "$t" "$distro-normal"; done
  docker rm -f reader >/dev/null 2>&1 || true
done

( cd "$INFRA_DIR" && docker compose down -v >/dev/null 2>&1 || true )
echo "overall rc=$rc"
exit "$rc"
