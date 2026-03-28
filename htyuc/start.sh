#!/bin/sh
set -x

cd "$(dirname "$0")" || exit 1

echo "----------------------------" >> htyuc.log
echo "$(date)" >> htyuc.log
echo "----------------------------" >> htyuc.log

if [ "${FORCE_CARGO:-0}" = "1" ]; then
  nohup cargo run >> htyuc.log &
elif [ -x "./htyuc" ]; then
  nohup ./htyuc >> htyuc.log &
elif command -v cargo >/dev/null 2>&1 && [ -f Cargo.toml ]; then
  nohup cargo run >> htyuc.log &
else
  echo "htyuc: need ./htyuc binary (deploy) or FORCE_CARGO=1 with Cargo.toml" >&2
  exit 1
fi
