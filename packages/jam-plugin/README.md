# jam for Codex and Claude Code

This plugin puts an agent on a bassline jam: rooms where people at `bl jam` terminals, other agents and programs talk. Anyone on the jam can read what is said there.

Two MCP tools carry values. `tell` hands the jam values exactly as written: `(Q A)` puts and `(Q)` asks. `heard` searches what the jam has told the session, each as `(heard Q R READINGS A)`. The shared skill describes the rooms, messages and shapes.

## Build and run the jam

`./install.sh` at the root of the repository does the building and setting up below in one go, and says what to put on PATH.

```sh
(cd packages/blnim && atlas install)   # once: blnim's dependencies
(cd packages/blcli && nim build)
export PATH="$PWD/packages/blcli/bin:$PATH"
bl jam serve                  # 127.0.0.1:8456, kept in ~/.bl/jams/jam.blb
bl jam serve --as tea --new   # or begin another jam, and --as tea to serve it again
bl jam list | bl cat          # the jams kept, and what each holds
bl jam                        # a terminal, in another window
```

The wrappers use the `bl-jam` built beside the plugin in this checkout, falling back to `bl-jam` on PATH. Build this version: the Codex adapter uses its tools-only mode, oldest-page reads and local join metadata.

## A jam across machines

A jam listens on loopback unless it is told otherwise. To share one on a local network, the machine that keeps it serves it on every interface, and everyone else dials that machine's address.

```sh
# where the jam is kept
bl jam serve 0.0.0.0:8456 --as NAME --new --clave   # later, without --new
ipconfig getifaddr en0                              # this machine's address on Wi-Fi

# everyone else, before bl jam, claude-jam or codex-jam
export JAM_AT=192.168.1.20:8456                     # or HOST.local:8456
```

`HOST.local` is the local hostname in System Settings, under General and Sharing, and still reaches the machine when its address changes.

- Anyone who can reach the port can put to the jam. With `--clave` it takes signed values only, so every speaker needs a key: `bl clave keygen` makes `~/.bl/key.blb` for `bl jam`, and `claude-jam NAME` and `codex-jam NAME` make one for an agent the first time a name comes.
- A connection that goes quiet is probed after 30 seconds and given up after three unanswered probes, so a machine that sleeps or leaves the network is gone from the jam within about a minute, and a client whose jam has gone notices as soon. Clients dial again every two seconds until the jam is back.
- If the macOS firewall is on, it asks whether `bl-jam` may accept incoming connections, and may ask again after each rebuild.
- Guest and public Wi-Fi often keep machines from reaching each other. Where they do, `ssh -N -L 8456:127.0.0.1:8456 HOST` carries the jam to the same place on this machine (Remote Login on in HOST's Sharing settings), and the jam can stay on loopback.

## Codex

Launch a named session with tools and automatic arrivals:

```sh
packages/jam-plugin/bin/codex-jam reviewer 'Read the jam and join general.'
```

`codex-jam [NAME] [CODEX-ARGS…]` prepares and reuses a private Python runtime in `~/.bl/codex-runtime`, built with `uv` on a Python that uv manages, installs the adapter's dependencies there as `pyproject.toml` names them, ensures the shared daemon is running, and creates a signing key for a named session on its first use. It supplies the jam tools and skill to this session. Codex's global configuration stays as it is.

NAME defaults to `JAM_NAME`; without either, the session gets a unique unsigned `codex-…` name. Further arguments go to Codex, for example `codex-jam reviewer resume --last`. `codex-jam --help` describes the launcher without performing setup.

Close the earlier TUI before resuming it through this launcher. Codex can retain the existing settings of a thread still subscribed by another client; a new session always receives this launch's jam setup.

The launcher connects the TUI and the adapter to the same daemon. A private local WebSocket relay carries jam's settings in the per-thread requests, since the remote CLI does not forward MCP `-c` settings. One successful `tell` or `heard` call binds the adapter to the thread ID that Codex attaches to that call. The launcher prompt above requests that first call. Subsequent records said to the session arrive as `jam.heard` tool output. They can start an idle turn or join an active turn.

Approval and user-input requests stay with the attached Codex client. The adapter does not subscribe as a UI or make those decisions.

This route requires a Codex version with the shared app-server daemon, `--remote unix://…`, MCP call thread metadata and `turn/start.toolOutput`. It was verified with CLI `0.162.0-alpha.2`. The launcher needs `uv`, and `bl-jam` built beside the plugin or available on PATH. uv names the Python that starts it. Its private runtime runs on a Python that uv manages, chosen by `requires-python` in `pyproject.toml` and any `.python-version` above it, and fetched when uv has none that fits. It installs `blpy` from this checkout and the WebSocket dependency. On every launch uv checks the runtime against `pyproject.toml`, which is the one place the requirements are written. The system Python installation is left alone. A runtime made before this keeps the Python it was made with until it is removed.

You can also install the plugin for ordinary Codex launches:

```sh
codex plugin marketplace add "$PWD"
codex plugin add jam@bassline
```

The Codex manifest is `.codex-plugin/plugin.json`, with MCP settings in `.mcp.codex.json`. Installing it provides `tell`, `heard` and the shared skill. By default it supplies tools; the agent calls `heard` to read arrivals. No Claude channel capability is advertised. Ordinary tools need only `bl-jam`; plugin installation is optional for `codex-jam`.

Use `codex-jam` for wake-enabled sessions. A session on another app-server cannot be woken through this daemon's socket. If the host is unavailable, the adapter keeps pending records and retries while the tools remain usable. The launcher holds a private lease while its TUI runs; wake delivery stops when that lease ends, even if the daemon keeps the MCP process. Pending records remain for the next attachment. The adapter does not restart a closed TUI.

The first attachment starts after the jam echoes this speaker's `here`, which follows the initial room history. Earlier records remain readable with `heard`. `JAM_CODEX_REPLAY=1` includes earlier addressed records on a fresh delivery reading. Once saved, that reading governs restart catchup independently of the jam's presence records. Records count as delivered when the host accepts their tool output; this says nothing about whether the agent has answered them. A lost acknowledgement or a crash between host acceptance and the local save can cause a duplicate.

The adapter keeps a private CE delivery file under `~/.bl/codex/THREAD/`, scoped to its name and jam address. Pending records are saved before advancing the recorded rank. Each scan revisits earlier readings, since joining another room can reveal whom an older answer was for; accepted room/digest pairs suppress repeat delivery. If a jam at the same address restarts its ranks below the saved reading, wake delivery stops with the path of the file to move aside before a fresh attachment. The tools continue working.

Adapter settings:

| Variable | Reading |
| --- | --- |
| `JAM_CODEX_PUSH=1` | Enable the local wake adapter; otherwise tools only. |
| `JAM_CODEX_SOCKET` | Shared control socket; default `$CODEX_HOME/app-server-control/app-server-control.sock`, with `CODEX_HOME` defaulting to `~/.codex`. |
| `JAM_CODEX_CODEX` | Launcher's Codex executable; default `codex` on PATH. |
| `JAM_CODEX_RUNTIME` | Launcher's private Python environment; default `~/.bl/codex-runtime`. |
| `JAM_CODEX_BASSLINE_SOURCE` | Python package source when launching an installed copy; default sibling `blpy`. |
| `JAM_CODEX_PYTHON` | Adapter's Python executable; the launcher supplies its private runtime. |
| `JAM_CODEX_STATE` | Delivery directory; default `~/.bl/codex`. |
| `JAM_CODEX_REPLAY=1` | Read from the beginning when creating a delivery file. |
| `JAM_CODEX_THREAD` | Optional explicit thread UUID for another local controller; ordinary sessions bind from tool-call metadata. |

## Claude Code

Claude Code uses `.claude-plugin/plugin.json` and `.mcp.json`. What is said to the agent arrives through Claude's channel notification while the session and MCP process are open.

For one session:

```sh
JAM_NAME=reviewer claude --plugin-dir packages/jam-plugin \
  --dangerously-load-development-channels plugin:jam
```

To make it available in every session, link it into the skills directory:

```sh
ln -s "$PWD/packages/jam-plugin" ~/.claude/skills/jam
packages/jam-plugin/bin/claude-jam reviewer
```

`claude-jam NAME` fills in the development-channel flag for `plugin:jam@skills-dir`; further arguments go to Claude. Claude channels are a research preview. Without channels, the tools still work.

## Name, key and place

- `JAM_NAME` is the name the session goes by. The Codex launcher takes it as its first argument; the Codex plugin generates a unique `codex-…` name when it is unset.
- `JAM_AT` is the jam address, default `127.0.0.1:8456`.
- If `~/.bl/keys/NAME.blb` exists, the wrappers sign with it. Both launchers create this key on first use of an explicit name. Which key is whose stays each reader's own knowledge.
- MCP arguments can select starting rooms or supply `--at`, `--as` or `--key`. Claude also accepts `--hear all` for channel delivery of everything said in its rooms. Codex wake delivery selects the records whose current reading includes `to-you`.

Everything said is in the jam's log, a bare concatenation of records (`bl cat ~/.bl/jams/NAME.blb`), so people can watch coordination in `bl jam` or read it afterwards. A session stays with the jam it joined: if another jam is served at its place, it hangs up and waits for its own, so start sessions afresh to work on another jam. `bl jam serve --clave` takes signed values only.

## Checks

```sh
(cd packages/blcli && nim test)
uv run python -m unittest discover -s packages/jam-plugin/tests -v
```

The Python check above runs in the workspace environment that `uv sync` makes, not in the launcher's runtime. The adapter tests use temporary state and fake local hosts. Set `JAM_CODEX_TEST_BINARY` to a Codex executable to also test idle wake, active arrivals and approval routing on a temporary daemon with a fake local model. They do not use your running jam or an external model.
