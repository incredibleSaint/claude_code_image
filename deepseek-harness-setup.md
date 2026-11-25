# DeepSeek Harness in the existing claude-box container

These files add [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) to `incredibleSaint/claude_code_image` without changing the existing `ccb`/`kcb` wrappers or their data.

Unlike `kcb -m deepseek-chat` (Kimi Code's harness driving DeepSeek models), this is DeepSeek's own agent harness — the Web UI, headless runner, and plugin system from DeepSeek AI.

## Files

- `Dockerfile`: installs Node.js 24 (dsh requires `^24.22.3 || >=26.13.1`) and `@deepseek-ai/dsh` globally.
- `dcb`: launcher, same pattern as `kcb`.
- `dcb-update`: installs/updates dsh + Node on the host, no rebuild needed.

## Install

The image needs a one-time rebuild for its fallback copy of Node + dsh:

```bash
cd ~/claude-box
install -m 0755 dcb dcb-update ~/.local/bin/   # a PATH dir; ~/bin works too if you have it

podman build --network host \
  -t claude-box \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  .

dcb-update   # newest dsh on the host; dcb prefers it over the image's copy
```

To pin versions, add `--build-arg DSH_VERSION=X.Y.Z` and/or `--build-arg NODE_VERSION=24.x.y` to the build, or run `dcb-update X.Y.Z` for the host copy.

## API key

dsh's built-in DeepSeek route reads `DEEPSEEK_API_KEY` per request. Either export it on the host (`dcb` passes it into the container when set):

```bash
export DEEPSEEK_API_KEY=sk-xxxxx
```

or save it once in dsh's own data (survives without the host variable):

```bash
dcb shell
echo 'DEEPSEEK_API_KEY=sk-xxxxx' > "$DSH_HOME/.env"
```

You can also enter the key in the Web UI under **Settings → Models**; it is stored write-only in `$DSH_HOME/.credentials.yaml`.

## Run

```bash
dcb                          # Web UI at http://127.0.0.1:3080 (no browser auto-open)
dcb headless "run the tests" # one task, answer on stdout, exit
dcb headless --json "..."    # machine-readable run events
dcb shell                    # shell inside the same sandbox
```

In the Web UI: choose **Settings → Models** if the key isn't set yet, then **Choose workspace** and add the project directory you started `dcb` from (the container mounts it at the same path as on the host).

`dcb web` defaults to `CCB_NETWORK=host` so the Web UI's `127.0.0.1:3080` is your host's loopback — the browser runs outside the container, and dsh refuses wildcard binds, so a published bridge port would not work. Note this also lets the agent reach the host's localhost services for that run; `dcb headless` and `dcb shell` keep the normal sandboxed network.

## Data and updates

- dsh configuration, credentials, profiles, and sessions: `~/.local/share/dsh-box/` (mounted as `$DSH_HOME`)
- Claude: `~/.local/share/claude-box/`, Kimi: `~/.local/share/kimi-box/` — all separate
- Update dsh with `dcb-update` (or `dcb-update X.Y.Z[-rc.N]` to pin/go back): it downloads Node (SHA-256 checked against nodejs.org's SHASUMS256) and the npm package into `~/.local/share/dsh-box-cli/`, which `dcb` mounts read-only instead of the image's copies. dsh is in developer preview and breaking changes are expected
- Plugins are managed per profile with `dsh plugin --profile <name> add <package>` (pnpm via corepack is in the image)
- Existing `ccb` sandbox settings and protections continue to apply
