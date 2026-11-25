# Kimi Code in the existing claude-box container

These files add native Kimi Code CLI support to `incredibleSaint/claude_code_image` without changing the existing `ccb` wrapper or Claude data.

## Files

- `Dockerfile.txt`: complete replacement for the repository's `Dockerfile`.
- `kcb.txt`: ready-to-install Kimi launcher.
- `kcb-update`: installs/updates Kimi Code on the host, no rebuild needed.

## Install

1. Download both files and place them in your local `claude_code_image` repository.
2. Rename `Dockerfile.txt` to `Dockerfile`, replacing the original. Keep a backup first if you have local changes.
3. Rename `kcb.txt` to `kcb`.
4. Install the launcher and rebuild:

```bash
cd ~/claude-box
install -m 0755 kcb kcb-update ~/.local/bin/   # a PATH dir; ~/bin works too if you have it

podman build --network host \
  -t claude-box \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  .
```

To build without the optional Qt/GUI Python packages, add `--build-arg WITH_GUI=0`.

To pin a specific Kimi release, add `--build-arg KIMI_CODE_VERSION=X.Y.Z` with a real version number. The default is `latest`.

## Run

From a project directory:

```bash
CCB_ENGINE=podman kcb --version
CCB_ENGINE=podman kcb
```

At the Kimi prompt, enter `/login`, choose **Kimi Code (OAuth)**, open the displayed link in your host browser, and complete device-code authorization.

Useful commands:

```bash
CCB_ENGINE=podman kcb                 # New session
CCB_ENGINE=podman kcb -c              # Continue the latest session
CCB_ENGINE=podman kcb -p "Explain this repository"
CCB_ENGINE=podman kcb shell           # Shell inside the same sandbox
CCB_ENGINE=podman CCB_GPU=all kcb     # Existing GPU support
```

To make Podman the default, add this to your shell configuration:

```bash
export CCB_ENGINE=podman
```

## DeepSeek (API key)

`kcb` supports DeepSeek through Kimi Code's OpenAI-compatible provider. The provider and models are declared in `~/.local/share/kimi-box/config.toml` (created for you), which reads the key from the `DEEPSEEK_API_KEY` environment variable — the key itself is never written to disk by Kimi Code.

1. Export your key on the host (e.g. in your shell configuration):

```bash
export DEEPSEEK_API_KEY=sk-xxxxx
```

2. Run `kcb` as usual — it passes `DEEPSEEK_API_KEY` into the container when set. Inside Kimi Code, pick the model with `/model` (`deepseek-chat` or `deepseek-reasoner`), or non-interactively:

```bash
CCB_ENGINE=podman kcb --model deepseek-chat -p "Explain this repository"
```

## Data and updates

- Kimi configuration, credentials, and sessions: `~/.local/share/kimi-box/`
- Claude configuration, credentials, and sessions: `~/.local/share/claude-box/`
- Kimi automatic updates are disabled. To update, run `kcb-update` (or `kcb-update X.Y.Z` to pin/go back): it runs Kimi's official installer (SHA-256 verified) into `~/.local/share/kimi-box-cli/`, which `kcb` then mounts read-only instead of the image's copy — no rebuild needed. Rebuilding the image also works and refreshes the fallback copy.
- Existing `ccb` sandbox settings and protections continue to apply.
