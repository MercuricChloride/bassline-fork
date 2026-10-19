#!/bin/sh
# Builds the jam prototype and runs it: a party on [::1], a keeper owning
# the lobby and general, ann and bob talking, ann opening kitchen, the
# keeper stopped and begun again on its log while bob says something
# and dave leaves, and carl joining late and catching up. What each
# printed is in out/.
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin="$here/bin"
out="$here/out"
cd "$here/../../../.."   # packages/blnim, whose nim.cfg holds the dependency paths
for p in party keeper chat; do nim c --hints:off "$here/$p.nim" > /dev/null; done
mkdir -p "$out"
: > "$out/jam.blb"

"$bin/party" > "$out/port" & party=$!
sleep 0.5
port=$(cat "$out/port")
"$bin/keeper" "$port" "$out/jam.blb" general > "$out/keeper.txt" & keeper=$!
sleep 0.5

"$bin/chat" "$port" ann '(join general)' '(wait 300)' '(post general "dinner is ready")' \
  '(open kitchen)' '(join kitchen)' '(post kitchen "the oven is on")' '(wait 4000)' \
  > "$out/ann.txt" & ann=$!
sleep 0.2
"$bin/chat" "$port" bob '(join general)' '(wait 500)' '(post general "coming")' \
  '(wait 1000)' '(post general "anyone there?")' '(wait 2500)' \
  > "$out/bob.txt" & bob=$!
"$bin/chat" "$port" dave '(join general)' '(wait 1500)' > "$out/dave.txt" & dave=$!

sleep 1.2
echo "-- the keeper stops" >> "$out/keeper.txt"
kill $keeper
wait $keeper 2> /dev/null || true
sleep 1
echo "-- the keeper begins again on its log" >> "$out/keeper.txt"
"$bin/keeper" "$port" "$out/jam.blb" >> "$out/keeper.txt" & keeper=$!

sleep 1
"$bin/chat" "$port" carl '(join general)' '(join kitchen)' '(wait 3000)' \
  > "$out/carl.txt" & carl=$!

wait $ann $bob $carl $dave
kill $keeper $party
wait $keeper $party 2> /dev/null || true
for f in keeper ann bob carl; do echo "--- $f"; cat "$out/$f.txt"; done
