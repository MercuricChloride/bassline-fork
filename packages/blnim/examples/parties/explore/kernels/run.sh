#!/bin/sh
## Builds the kernels and runs the examples against each, unchanged:
## basics through shim/, so its serve and attend reach the kernel named
## in KERNEL, and probe, values and bl party attending the kernel served
## on [::1] at a port of its own. What each says goes to out/.
set -u
K=$(cd "$(dirname "$0")" && pwd)
BLNIM=$(cd "$K/../../../.." && pwd)
BLBIN=$BLNIM/../blcli/bin/bl
OUT=$K/out
TOPICS='{status (kitchen) (desk)}'
mkdir -p "$OUT" "$K/bin" "$K/home"
trap 'kill $(jobs -p) 2>/dev/null' EXIT  # every party this started

bl() { HOME=$K/home "$BLBIN" "$@"; }  # so bl reads no one's config

cd "$BLNIM" || exit 1
for f in stock sealed veiled gated recorder fence probe; do
  nim c --hints:off --warnings:off -o:"$K/bin/$f" "$K/$f.nim" || exit 1
done
sed -e 's#^import \.\./core$#import bl/core#' -e 's#^import \./place$#import bl/parties/place#' \
  src/bl/parties/parties.nim > "$K/shim/stock_parties.nim"
nim c --hints:off --warnings:off --skipProjCfg --path:"$BLNIM/src" --path:"$K/shim" \
  --nimcache:"$K/nimcache/basics" -o:"$K/bin/basics" examples/parties/basics.nim || exit 1

: > "$OUT/basics.log"
for k in stock base sealed veiled gated recorder fence; do
  KERNEL=$k LOG=$OUT/basics.log TOPICS=$TOPICS timeout 20 "$K/bin/basics" > "$OUT/basics-$k.txt" 2>&1
done

stop() { kill "$@"; wait "$@" 2>/dev/null; }

party() {  # party NAME CMD…: serves a party in the background, setting PID and PORT
  name=$1
  shift
  : > "$OUT/$name.party"
  "$@" >> "$OUT/$name.party" 2>&1 &
  PID=$!
  while [ ! -s "$OUT/$name.party" ]; do sleep 0.05; done
  PORT=$(sed -n '1s/.*\]:\([0-9]*\).*/\1/p' "$OUT/$name.party")
}

values() {  # values BINARY: builds values.nim to attend the party at PORT
  nim c --hints:off --warnings:off -d:partyPort="$PORT" --nimcache:"$K/nimcache/values" \
    -o:"$1" examples/parties/values.nim || exit 1
}

against() {  # against NAME: probe, values and bl party at the party at PORT
  "$K/bin/probe" "$PORT" > "$OUT/probe-$1.txt" 2>&1
  values "$K/bin/values"
  : > "$OUT/values-$1.txt"
  BL_PARTY=::1 "$K/bin/values" cook >> "$OUT/values-$1.txt" 2>&1 &
  cook=$!
  sleep 0.3
  BL_PARTY=::1 "$K/bin/values" guest >> "$OUT/values-$1.txt" 2>&1
  stop $cook
  timeout 5 env HOME="$K/home" "$BLBIN" party --sink -n 1 --at "[::1]:$PORT" '(kitchen)' | bl cat > "$OUT/blparty-$1.txt" &
  sink=$!
  sleep 0.3
  echo '(hello "from bl party")' | bl read | bl party --source --at "[::1]:$PORT" '(kitchen)'
  wait $sink
}

party stock "$K/bin/stock"; against stock; stop $PID
party sealed "$K/bin/sealed"; against sealed; stop $PID
party veiled "$K/bin/veiled"; against veiled; stop $PID
party gated "$K/bin/gated" "$TOPICS"; against gated; stop $PID

: > "$OUT/recorder.log"
party recorder "$K/bin/recorder" "$OUT/recorder.log"; against recorder; stop $PID
party recorder-again "$K/bin/recorder" "$OUT/recorder.log"
"$K/bin/probe" "$PORT" > "$OUT/probe-recorder-again.txt" 2>&1
stop $PID
"$K/bin/recorder" "$OUT/recorder.log" show > "$OUT/recorder-log.txt"

party inner "$K/bin/stock"
INNER=$PORT
INNERPID=$PID
party fence "$K/bin/fence" "$INNER" "$TOPICS"; against fence

# The sandbox: the guest can reach the fence's port alone. The cook
# attends the party inside directly.
cat > "$OUT/sandbox.sb" <<SB
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:$PORT"))
SB
FENCE=$PORT
PORT=$INNER
values "$K/bin/values-inner"
: > "$OUT/sandbox.txt"
BL_PARTY=::1 "$K/bin/values-inner" cook >> "$OUT/sandbox.txt" 2>&1 &
cook=$!
sleep 0.3
BL_PARTY=::1 sandbox-exec -f "$OUT/sandbox.sb" "$K/bin/values" guest >> "$OUT/sandbox.txt" 2>&1
echo '(sneak)' | bl read |
  HOME=$K/home sandbox-exec -f "$OUT/sandbox.sb" "$BLBIN" party --source --at "[::1]:$INNER" '(kitchen)' >> "$OUT/sandbox.txt" 2>&1
stop $cook $PID $INNERPID
echo "fence at $FENCE, the party inside at $INNER" >> "$OUT/sandbox.txt"
