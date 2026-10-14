#!/bin/sh
# install.sh: the bl toolkit and the jam, built from this checkout.
#
# Checks for Nim 2.2.10 or later and atlas (installing atlas with nimble
# if it isn't there), fetches blnim's dependencies the first time,
# builds packages/blcli/bin/bl, bl-clave and bl-jam, links the jam
# plugin for Claude Code, makes your key, ~/.bl/key.blb, if there isn't
# one, and says what to put on PATH. Run again, it rebuilds and leaves
# the rest as it is.
set -eu

root=$(cd -P "$(dirname "$0")" && pwd)
bin=$root/packages/blcli/bin
plugin=$root/packages/jam-plugin
deps=$root/packages/blnim/deps

say() { printf -- '-- %s\n' "$*" >&2; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

command -v nim >/dev/null 2>&1 ||
  die "no nim on PATH: brew install nim, or choosenim stable (Nim 2.2.10 or later)"
version=$(nim --version 2>/dev/null | sed -n 's/^Nim Compiler Version \([0-9.]*\).*/\1/p')
printf '%s\n' "$version" |
  awk -F. '{ exit !($1 > 2 || ($1 == 2 && ($2 > 2 || ($2 == 2 && $3 >= 10)))) }' ||
  die "nim ${version:-of no known version} is too old: blnim wants 2.2.10 or later"

if ! command -v atlas >/dev/null 2>&1; then
  command -v nimble >/dev/null 2>&1 || die "no atlas, and no nimble to install it with"
  say "installing atlas with nimble"
  nimble install -y atlas
  command -v atlas >/dev/null 2>&1 ||
    die "atlas is installed but not on PATH: add ~/.nimble/bin to PATH and run this again"
fi

if [ -d "$deps/bigints" ] && [ -d "$deps/checksums" ] && [ -d "$deps/nimcrypto" ]; then
  say "blnim's dependencies are in $deps already"
else
  say "fetching blnim's dependencies into $deps"
  (cd "$root/packages/blnim" && atlas install)
  for d in bigints checksums nimcrypto; do
    [ -d "$deps/$d" ] || die "atlas install left no $deps/$d"
  done
fi

# a bl-jam running from bin, a jam or an agent's line, would be built over
if ps -axo command= | grep -F "$root/packages/" | grep -q "blcli/bin/bl-jam"; then
  die "a bl-jam built here is running (a jam, or an agent on one): stop it, then run this again"
fi
say "building $bin/bl, bl-clave and bl-jam"
(cd "$root/packages/blcli" && nim --hints:off build)

link=$HOME/.claude/skills/jam
if [ -L "$link" ] || [ ! -e "$link" ]; then
  mkdir -p "$HOME/.claude/skills"
  ln -sfn "$plugin" "$link"
  say "linked $link to $plugin"
else
  say "$link is there and isn't a link, so it is left alone (claude-jam wants it to be $plugin)"
fi
command -v claude >/dev/null 2>&1 || say "no claude on PATH: claude-jam needs Claude Code"
command -v uv >/dev/null 2>&1 || say "no uv on PATH: codex-jam needs it (brew install uv)"

if [ -e "$HOME/.bl/key.blb" ]; then
  say "your key is $HOME/.bl/key.blb"
else
  "$bin/bl" clave keygen
fi

case ":$PATH:" in
  *":$bin:"*) ;;
  *) say "put the tools on PATH, in ~/.zshrc too:"
     printf '\n  export PATH="%s:%s:$PATH"\n\n' "$bin" "$plugin/bin" >&2 ;;
esac

at=$(ipconfig getifaddr en0 2>/dev/null || true)
cat >&2 <<EOF
To keep a jam others on this network can reach:

  bl jam serve 0.0.0.0:8456 --as NAME --new --clave   (later, without --new)

and tell them this machine's address, ${at:-from ipconfig getifaddr en0}:8456.
To join a jam on another machine:

  export JAM_AT=ADDRESS:8456
  bl jam                  a terminal
  claude-jam NAME         Claude Code, going by NAME
  codex-jam NAME          Codex

packages/jam-plugin/README.md says more, under "A jam across machines".
EOF
