# claude-box

Run [Claude Code](https://code.claude.com/docs) in a Docker container for the current project. Claude Code works with the files the container can see, and its commands run inside the container, not on your host.

- **Internet: yes.** The model runs on Anthropic's servers, so Claude Code can't work offline. Everything the agent reads (files, command output) is sent to Anthropic. **Use it only for repositories that may be sent there.** For the others, keep using `opencode-offline` with the local model.
- **Your host: mostly out of reach.** The container sees only the project, the folders you add, and its own data folder. It doesn't see `~/.ssh`, other repos, or your host's Claude Code login. It runs as your UID, with no root and no capabilities.
- **Options:** NVIDIA GPU + your host's CUDA toolkit (`CCB_GPU`), Mellanox RDMA devices (`CCB_RDMA`), VFs or ports for packet RX/TX and DPDK (`CCB_NET`), a host Python venv (`CCB_VENV`).

It's built like `opencode-offline`: the same wrapper design, the same Python packages, and the same Mellanox modes. The differences are the network, Claude Code's login and data, and the GPU option.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image: Ubuntu 24.04, Claude Code (pinned version), build tools, RDMA userspace, Python venv |
| `ccb` | Wrapper that starts the container for the current project |
| `ccb-update` | Installs or updates Claude Code for the box on the host, without rebuilding the image |
| `claude-box.md` | Environment notes for Claude (no sudo, where CUDA is, …), installed as `/etc/claude-code/CLAUDE.md` in the image |
| `requirements.txt`, `requirements-gui.txt` | Python packages of `/opt/venv`: the same as in `opencode-offline`, plus pandas |
| `seccomp.json` | Docker's default seccomp profile plus io_uring (for `liburing`); installed to `~/.config/claude-box/` |
| `claude-box-nolan.service` | Optional: keeps the container off your LAN and off the host (see [Blocking the LAN](#blocking-the-lan-optional)) |

Keep this folder, e.g. `~/claude-box`; the image is built from it.

---

## One-time setup

### 1. Prerequisites

Docker must work without sudo (`docker ps`). If you get `permission denied ... docker.sock`:

```zsh
sudo usermod -aG docker $USER   # then log out and back in
```

### 2. Build the image

Pass your UID/GID, so that files created in the container belong to you:

```zsh
cd ~/claude-box
docker build -t claude-box --build-arg UID=$(id -u) --build-arg GID=$(id -g) .
```

The build downloads Claude Code and about 2 GB of Python packages (about 0.8 GB with `--build-arg WITH_GUI=0`, which leaves out Qt). The image contains no CUDA: it comes from the host (see [GPU and CUDA](#gpu-and-cuda)).

### 3. Install the `ccb` wrapper (zsh)

```zsh
mkdir -p ~/bin
cp ccb ccb-update ~/bin/ && chmod +x ~/bin/ccb ~/bin/ccb-update
grep -q 'path=("$HOME/bin"' ~/.zshrc || echo 'typeset -U path; path=("$HOME/bin" $path)' >> ~/.zshrc
source ~/.zshrc
rehash
which ccb        # -> /home/<you>/bin/ccb
```

The name is `ccb` (Claude Code box), not `cc`, which is the C compiler.

Install the seccomp profile. Docker's default profile blocks io_uring, so `liburing` code would fail with `EPERM`; this one is Docker's default plus the three io_uring calls:

```zsh
mkdir -p ~/.config/claude-box && cp seccomp.json ~/.config/claude-box/
```

It lives outside the data folder, so the agent can't change it. Without the file, `ccb` uses Docker's default profile.

### 4. Log in (once)

```zsh
cd ~/projects/some-repo && ccb
```

On the first start, Claude Code asks for a theme and a login method. Choose your Claude account (Pro/Max/Team/Enterprise) or a Console account:

1. The container can't open a browser, so Claude Code prints a URL. Copy it with the mouse and open it in your browser on the host.
2. Sign in. The browser then shows a code, because it can't reach the container's callback.
3. Paste the code at `Paste code here if prompted`.

The login is stored in `~/.local/share/claude-box/.credentials.json`, so you log in once, not per run. It is separate from a Claude Code installed on the host. When Claude Code warns that the login expires soon, run `/login` inside.

Then Claude Code asks whether you trust the folder. It asks once per project; the answer is kept in the same data folder.

**Alternative: a token.** `ccb claude setup-token` runs the same browser flow and prints a one-year token instead of storing a login. Put it in `~/.zshrc` as `export CLAUDE_CODE_OAUTH_TOKEN=...` and start with `CCB_ENV=CLAUDE_CODE_OAUTH_TOKEN ccb`. Such a token can only make model requests: Remote Control and claude.ai connectors don't work with it. The normal login is simpler.

### 5. Verify

```zsh
cd ~/projects/some-repo
ccb claude --version
ccb claude doctor                    # "Auto-updates: disabled", "Search: OK (bundled)"
ccb bash -c 'id; pwd; curl -sI https://api.anthropic.com | head -1'
```

`id` must show your UID, and `pwd` the same path as on the host. `claude doctor` warns that the "config install method is 'unknown'" and suggests `claude install`. Ignore that: the image manages the installation, not Claude Code's updater.

---

## Daily use

```zsh
cd ~/projects/phy && ccb
```

| Command | What it does |
|---|---|
| `ccb` | Claude Code in the current project |
| `ccb -c` | continue the last conversation in this project |
| `ccb -r` | pick an earlier conversation |
| `ccb -p "prompt" < /dev/null` | non-interactive run; without `< /dev/null` it waits 3 s for stdin |
| `ccb bash` | shell inside the same sandbox (build, test, inspect) |
| `ccb claude <anything>` | any other `claude` command, e.g. `ccb claude mcp list` |

Arguments that start with `-` go to `claude`, so `ccb -c --model opus` works. Any other first argument is a command, e.g. `ccb make -j`.

Suggested aliases, like the ones for `oc`:

```zsh
alias ccg='CCB_GPU=all ccb'                                              # + GPU and CUDA
alias ccr='CCB_RDMA=1 ccb'                                               # + RDMA verbs
alias ccn='CCB_NET_ALLOW_PF=1 CCB_NET="enp1s0f0np0 enp1s0f1np1" ccb'     # + both ports; default command: bash
```

### What gets mounted

| Host | Container | Mode |
|---|---|---|
| The git repo root of the current folder | Same path | writable |
| Git's object store, if the repo is a worktree or submodule (it lives outside the checkout) | Same path | writable |
| `CCB_RO` / `CCB_RW` folders | Same paths | read-only / writable |
| `~/.local/share/claude-box` | `/home/dev/.claude` (`CLAUDE_CONFIG_DIR`) | writable |
| `~/.local/share/claude-box-cli` (after `ccb-update`) | `/opt/claude-cli` (Claude Code itself) | read-only |
| With `CCB_GPU`: `/usr/local/cuda-X.Y` | Same path and `/usr/local/cuda` | read-only |
| `/etc/localtime` | Same | read-only |

Same paths mean compiler errors, CMake caches and `compile_commands.json` work unchanged, and Claude Code finds the project's conversations and folder trust by path. It starts in the current folder.

`ccb` refuses to mount your home folder or anything above it. Outside a git repo, only the current folder is mounted. With a dotfiles repo at `~`, it also mounts only the current folder, not `~`.

Inside, commits get your name and email from your git config (`GIT_AUTHOR_*` / `GIT_COMMITTER_*`). Your `~/.gitconfig` itself isn't mounted, and neither are SSH keys, so the agent can commit but can't push. Push from the host.

### Extra folders

```zsh
CCB_RO="/opt/gcc-14.2 $HOME/src/dpdk-25.11" ccb     # read-only
CCB_RW="$HOME/projects/common-lib" ccb              # writable
```

Folders are mounted at their host paths, so a toolchain at `/opt/gcc-14.2` keeps working. Don't mount system directories like `/usr/include`, which would hide the container's own. Paths with spaces are not supported by these variables.

### Compilers and tools

GCC 13 is the default (`gcc`, `g++`); GCC 14 is installed next to it: `CC=gcc-14 CXX=g++-14` or `-DCMAKE_CXX_COMPILER=g++-14`. Also in the image: liburing, GoogleTest and GMock (`find_package(GTest)` works), libnuma, pkg-config, ethtool, `lspci`, numactl, and CMake, Ninja and gdb as before.

**A compiler from the host, e.g. GCC 15** built with `--prefix=/opt/gcc-15`:

```zsh
CCB_RO=/opt/gcc-15 CCB_PATH=/opt/gcc-15/bin ccb
```

Then `gcc`/`g++` inside are GCC 15. This works for a compiler installed into its own folder. Its support libraries (GMP, MPFR, MPC, ISL) must be built in or present in the image (Ubuntu 24.04 has them for GCC 13), and it must have been built for a glibc no newer than Ubuntu 24.04's 2.39. Debian 12 / Astra builds are fine. Programs built with it need its newer `libstdc++`: link with `-Wl,-rpath,/opt/gcc-15/lib64`, or `-static-libstdc++`. A GCC 15 from apt (`/usr/bin/gcc-15`) is spread over `/usr` and can't be mounted like this; install it in the image instead.

**Network tools:** tshark, tcpdump and termshark (a terminal UI for tshark), tcpreplay/tcprewrite, trafgen and mausezahn (netsniff-ng), iperf3, netcat, socat, ping/arping/traceroute/mtr, dig, nmap, lsof and strace.

- **Reading pcaps works in every mode.** For MPEG-TS on your UDP port: `tshark -r cap.pcap -d udp.port==4712,mp2t`.
- **Capturing live traffic needs `CAP_NET_RAW`,** so only with `CCB_RAW` or `CCB_NET`. Without it: `socket: Operation not permitted`. With `CCB_NETWORK=host CCB_RAW=...` you can capture on every host interface.
- **Capturing on the RDMA device** (`tcpdump -i mlx5_0`, listed in `tcpdump -D`) shows traffic that bypasses the kernel: raw packet QPs, DPDK, RoCE. A capture on the netdev (`-i enp1s0f1np1`) doesn't see it. The device must be passed (`CCB_RAW` includes it). This is a feature of libpcap and mlx5; I couldn't test it without a card.
- **No Wireshark GUI:** the box has no display. Save a capture into the project (`-w cap.pcapng`) and open it in Wireshark on the host, or use `termshark` inside.

**podman** is installed, but it can't start or build containers inside the box: that needs privileges the container doesn't have (`cannot clone: Operation not permitted`). Run container steps on the host. The only way to give the agent real container access is the host's podman or Docker socket, which is equivalent to root on the host.

### Python

The image has the same venv as `opencode-offline` (`/opt/venv`, Python 3.12, the packages from `requirements.txt` and, with `WITH_GUI=1`, `requirements-gui.txt`). See that README for the package list and what was left out.

Differences:
- **pandas 3.0.6 added.** It works with the pinned numpy 1.26.4 (`pip check` clean). pandas 3.0 turns on copy-on-write and a dedicated string type by default. If your scripts rely on pandas 2 behaviour, pin `pandas==2.3.3` instead. To have pandas in `opencode-offline` too, copy this `requirements.txt` there and rebuild that image.
- **`pip install` works during a run.** The container has internet and the venv belongs to `dev`. The package is gone when the container exits. For permanent packages, add them to `requirements.txt` and rebuild; only the venv and Claude Code layers re-run.
- **Host venvs:** `CCB_VENV=.venv ccb` works exactly like `OC_VENV` (mounted read-only at its path, activated, interpreter checked: uv/pyenv interpreters are mounted automatically, a system Python must match the image's 3.12).

`MPLBACKEND=Agg` and `QT_QPA_PLATFORM=offscreen` are set: there is no display.

### Wrapper settings

| Variable | Default |
|---|---|
| `CCB_ENGINE` | `docker` (`podman` works too; rootless gets `--userns=keep-id`) |
| `CCB_IMAGE` | `claude-box` |
| `CCB_DATA` | `~/.local/share/claude-box` (login, settings, conversations) |
| `CCB_NETWORK` | the `claude-box` network if it exists (see [Blocking the LAN](#blocking-the-lan-optional)), otherwise the engine's default bridge |
| `CCB_ENV` | names of host variables to pass in, e.g. `CLAUDE_CODE_OAUTH_TOKEN` |
| `CCB_SHM` | `4g`: size of `/dev/shm` (Docker's default of 64 MB is too small for CUDA IPC, DPDK or multiprocessing) |
| `CCB_GPU` | off. `all`, `0`, `0,1` or `GPU-<uuid>` (see [GPU and CUDA](#gpu-and-cuda)). Note: `0` means GPU 0; to turn it off, unset it or set `none` |
| `CCB_GPU_CAPS` | `compute,utility` |
| `CCB_CUDA` | with `CCB_GPU`: `/usr/local/cuda` if present. A path picks another version; `0` = no toolkit |
| `CCB_RO`, `CCB_RW` | extra read-only / writable folders |
| `CCB_VENV` | host venv instead of `/opt/venv` |
| `CCB_PATH` | folders to put first on `PATH`, e.g. `/opt/gcc-15/bin` (mount them with `CCB_RO`) |
| `CCB_SECCOMP` | `~/.config/claude-box/seccomp.json` if present (io_uring allowed); `default` = Docker's own profile |
| `CCB_RDMA` | `1` = all Mellanox RDMA devices, or a list of interfaces/devices (`enp1s0f1np1`, `mlx5_0,mlx5_1`) = only those (see [Mellanox / RDMA](#mellanox--rdma)) |
| `CCB_RAW` | `1` (or a list of ports, like `CCB_RDMA`) = RDMA devices plus `CAP_NET_RAW` for raw packets and DPDK, without moving interfaces (see [Host networking with raw packets](#host-networking-with-raw-packets-ccb_raw)) |
| `CCB_NET` | interface name(s) to move into the container (see [`CCB_NET`](#packet-rxtx-and-dpdk-ccb_net)) |
| `CCB_NET_ALLOW_PF` | `1` = allow physical ports in `CCB_NET` |
| `CCB_NET_IP` | `0` = don't copy the interfaces' host IP addresses into the container |

---

## GPU and CUDA

**Yes, the container uses CUDA from the host**, in two parts:

- **The driver** (kernel module, `libcuda.so`, `libnvidia-ml.so`, `nvidia-smi`, `/dev/nvidia*`) is always the host's. The NVIDIA Container Toolkit adds its libraries and device nodes when the container starts, so they match the running kernel module. They must never be in the image.
- **The toolkit** (`nvcc`, `cudart`, cuFFT, cuBLAS, headers, `compute-sanitizer`, `cuda-gdb`) is your host's `/usr/local/cuda-X.Y`, mounted read-only. The image contains nothing from CUDA, so the container always has exactly the CUDA you build with on the host, and there are no 5+ GB of toolkit in the image.

### Host setup, once

Install the NVIDIA Container Toolkit (the same on Ubuntu 24.04 and Debian 12 / Astra):

```zsh
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit

# Docker
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

# Podman (CDI): generate the device spec; again after every driver update
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list
```

Check which toolkit `/usr/local/cuda` points to. With both 12.5 and 13.3 installed, it's usually the one installed last:

```zsh
readlink -f /usr/local/cuda        # e.g. /usr/local/cuda-13.3
```

### Use

```zsh
CCB_GPU=all ccb                                  # all GPUs + /usr/local/cuda
CCB_GPU=0 ccb                                    # only GPU 0
CCB_GPU=all CCB_CUDA=/usr/local/cuda-12.5 ccb    # another toolkit version
CCB_CUDA=/usr/local/cuda ccb                     # toolkit only: compile, no GPU
```

To always have the GPU, put `export CCB_GPU=all` in `~/.zshrc`.

Check:

```zsh
CCB_GPU=all ccb bash -c 'nvidia-smi -L; nvcc --version | tail -2; echo $CUDACXX'
```

With `CCB_GPU`, the wrapper:
- Passes the GPU(s): `--gpus` with Docker, CDI `--device nvidia.com/gpu=...` with Podman.
- Mounts the toolkit at its real path (`/usr/local/cuda-13.3`) and at `/usr/local/cuda`. So both CMake caches from the host and scripts that hard-code `/usr/local/cuda` work.
- Sets `PATH` (with `nvcc`), `CUDA_HOME`, `CUDA_PATH`, `LD_LIBRARY_PATH` and `CUDACXX`. `CUDACXX` means CMake finds nvcc without the `CMAKE_CUDA_COMPILER` fix you needed on the host.

### Things to know

- **VRAM is shared with llama-server.** On the RTX 5090 machine, a running llama-server with Qwen3.8-27B holds most of the 32 GB. CUDA programs in the container then fail with out-of-memory errors. Stop llama-server for GPU-heavy work, or check `nvidia-smi` first.
- **Host compiler.** nvcc uses the container's GCC 13 (Ubuntu 24.04), which CUDA 12.4 and later supports (so your 12.5 and 13.3). For your GCC 14 build: `CCB_RO=/opt/gcc-14.2 ccb`, then `-ccbin /opt/gcc-14.2/bin/g++` or `CMAKE_CUDA_HOST_COMPILER`.
- **Driver capabilities.** The default `compute,utility` gives CUDA and `nvidia-smi`. For NVENC/NVDEC use `CCB_GPU_CAPS=compute,utility,video`; for OpenGL/EGL/Vulkan add `graphics`, or use `all`. This applies to Docker; with Podman, CDI passes all driver libraries anyway.
- **Profilers.** `nsys` often lives in `/opt/nvidia/nsight-systems`: add `CCB_RO=/opt/nvidia`. `ncu` needs GPU performance counters, which the driver restricts to root by default (`ERR_NVGPUCTRPERM`). To allow them, set on the host: `options nvidia NVreg_RestrictProfilingToAdminUsers=0` in `/etc/modprobe.d/`, then reboot.
- **GPU + RDMA together:** `CCB_GPU=all CCB_RDMA=1 ccb` (or with `CCB_NET`). GPUDirect RDMA (`ibv_reg_dmabuf_mr` on CUDA memory) then behaves exactly as on the host: the container adds no limits, but it can't remove the host's (GeForce, `nvidia-peermem`, PCIe topology).
- **Toolkit from another distro.** A toolkit installed on Debian 12 / Astra runs in the Ubuntu 24.04 container as well (newer glibc).

---

## Mellanox / RDMA

The same modes as in `opencode-offline`. Off by default.

```zsh
cd ~/projects/phy && CCB_RDMA=1 ccb
```

This passes `/dev/infiniband/uverbs*` and `/dev/infiniband/rdma_cm` into the container, and sets unlimited locked memory (`memlock`), which memory registration needs. The image contains rdma-core with the mlx5 provider, the verbs/rdma_cm headers and libraries, `ibv_*` tools, perftest and `rdma`.

### One-time host check

```zsh
ibv_devices                  # lists mlx5_0 ... ; if empty, the mlx5_ib module isn't loaded
ls -l /dev/infiniband        # uverbs* must be crw-rw-rw- (rdma-core's udev rule)
rdma system show             # must say "netns shared"
```

- **Device permissions.** If `uverbs*` are not `rw` for others, the container user can't open them. Fix it on the host with a udev rule: `KERNEL=="uverbs*", MODE="0666"`.
- **OFED version.** If the host runs MLNX_OFED or DOCA-OFED instead of the inbox driver, replace the RDMA `apt-get` block in the Dockerfile with the matching NVIDIA userspace packages and rebuild.

### Check inside the container

```zsh
CCB_RDMA=1 ccb bash
ulimit -l                                   # unlimited
ibv_devices; ibv_devinfo -d mlx5_0          # port state PORT_ACTIVE
# loopback bandwidth through the NIC (RoCE: add -x <gid-index>; see show_gids on the host)
ib_write_bw -d mlx5_0 & sleep 1; ib_write_bw -d mlx5_0 localhost
```

### What works and what doesn't

Unlike `opencode-offline`, the container has a network, but only its own bridge interface. The Mellanox netdevs and their IP addresses stay on the host.

| Works with `CCB_RDMA=1` | Doesn't work (use [`CCB_NET`](#packet-rxtx-and-dpdk-ccb_net)) |
|---|---|
| Opening devices, `ibv_reg_mr`, creating QPs/CQs | Receiving/sending raw Ethernet packets: raw packet QPs and `ibv_create_flow` fail with `EPERM` (no `CAP_NET_RAW`) |
| Building and running verbs code against the local NIC | DPDK with the mlx5 PMD (needs `CAP_NET_RAW`, the NIC's netdev and hugepages) |
| Loopback tests on one host | `rdma_cm` address resolution (it routes through the container's own interface, which has no RDMA device) |

Tools that exchange QP information over plain TCP (perftest without `-R`) can reach another host through the container's network as the client, and the RDMA traffic then uses the host port's GID. That wasn't tested. For multi-host work, `CCB_NET` is the reliable way.

`ibstat` and other MAD tools don't work in either mode: `umad` is not passed on purpose.

### Packet RX/TX and DPDK (`CCB_NET`)

For receiving and transmitting packets, give the container one **SR-IOV VF** (or a port) for the duration of a run:

```zsh
cd ~/projects/phy
CCB_NET=enp1s0f0v0 ccb ./build/phy --your-args     # run one test
CCB_NET=enp1s0f0v0 ccb                             # shell (default command is bash here)
CCB_NET=enp1s0f0v0 ccb claude                      # Claude Code with the VF
CCB_NET="enp1s0f0v0 enp1s0f1v0" ccb ...            # both ports: one VF on each
CCB_NET_ALLOW_PF=1 CCB_NET="enp1s0f0np0 enp1s0f1np1" ccb ...   # both physical ports themselves
```

`CCB_NET` takes a list (spaces or commas). Each port of a dual-port ConnectX is its own PCI function with its own RDMA device, so every listed interface brings its own `uverbs` node. Inside, `$CCB_NET` and `$CCB_IBDEV` are space-separated lists in the same order, e.g. `enp1s0f0np0 enp1s0f1np1` and `mlx5_0 mlx5_1`.

**VFs or the physical ports?** Prefer one VF per port, so the host keeps both ports for everything else. Use the physical ports when you need what a VF can't do, such as full line rate on one function, PF-only flow steering or port settings. During the run they disappear from the host. The wrapper protects you:

- **Default route: refused.** A port that carries the host's default route is never moved, so you can't cut off your own SSH.
- **Bond or bridge members: refused.** Take the port out of the bond first. With RoCE LAG, the two ports share one `mlx5_bond_0` device and can't be split.
- **IP addresses are carried over.** See [IP addresses](#ip-addresses-inside-the-container) below.

What the wrapper does:

1. Starts the container as usual (all capabilities dropped), plus `CAP_NET_RAW`, `CAP_NET_ADMIN`, unlimited `memlock`, only **the listed interfaces'** `uverbs` devices, `rdma_cm`, and `/dev/hugepages` if the host has it mounted. `CCB_GPU` applies here too.
2. Moves each listed interface into the container's network namespace with `sudo ip link set <if> netns <pid>`, brings it up, and copies its host IP addresses in. This step asks for your sudo password.
3. Runs your command as `dev` (your UID), with only `NET_RAW` and `NET_ADMIN` as capabilities, so files it creates belong to you.
4. On exit, Ctrl-C or kill, moves the interfaces back to the host (`sudo nsenter ... ip link set <if> netns 1`), restores their addresses and up state, and removes the container.

The container keeps its normal network (and default route) next to the moved interfaces.

### IP addresses inside the container

Moving an interface into another network namespace makes the kernel drop its IPv4 and global IPv6 addresses. MTU and link state stay, and IPv6 creates a new link-local `fe80::` address. So the wrapper:

- **Copies addresses in.** Each interface's global addresses are copied from the host into the container, with their subnet route. Set `CCB_NET_IP=0` to skip this.
- **Restores them on the host** after the run, together with the up/down state.

| Needs no IP | Needs an IP on the port |
|---|---|
| DPDK, raw packet QPs (`IBV_QPT_RAW_PACKET`), flow rules | RoCE v2 connections (GIDs are derived from the IP), `rdma_cm`, sockets (UDP/TCP) |

A VF usually has no address on the host. Give it one inside the container (the capabilities allow it):

```zsh
ip addr add 10.10.0.5/24 dev $CCB_NET
```

After adding an IPv4 address, the matching RoCE v2 GID appears in the GID table within a moment (check with `show_gids`, or `ibv_devinfo -v` for the GID list).

**Host setup, once** (root):

```zsh
for PF in enp1s0f0np0 enp1s0f1np1; do               # one VF on each port
  echo 1 > /sys/class/net/$PF/device/sriov_numvfs
  ip link set $PF vf 0 trust on        # VF may use promiscuous / all-multicast (multicast RX)
  ip link set $PF vf 0 spoofchk off    # only if you transmit with a source MAC other than the VF's
  ip link set $PF vf 0 vlan 100        # recommended: pin the VF to an isolated VLAN
done
ip -br link                          # the VF netdevs appear, e.g. enp1s0f0v0, enp1s0f1v0
rdma system show                     # must say "netns shared"
```

The VF names depend on your udev naming; use what `ip -br link` shows. VFs don't survive a reboot; make them persistent with a systemd unit or udev rule.

The wrapper uses `sudo` for four host commands: moving interfaces in (`ip link set ... netns`), moving them back (`nsenter --net=... ip link set ... netns 1`), and restoring addresses and link state (`ip addr add`, `ip link set ... up`). A long run can outlast sudo's password cache (15 minutes by default); you are then asked again at the end. A `NOPASSWD` rule for these would need wildcards over `ip` and `nsenter`, which amounts to passwordless root, so keep the prompt.

**Rules and limits:**

- **VFs only by default.** A physical port is refused unless you set `CCB_NET_ALLOW_PF=1`.
- **Rootful engine only.** Before kernel 6.17, `CAP_NET_RAW` for RDMA is checked in the host's user namespace. Rootless Podman gets `EPERM` even with `--cap-add`, so the wrapper refuses it. Docker (rootful) works.
- **Not macvlan, not `--network host`.** DPDK's mlx5 driver needs the real mlx5 netdev.
- **DPDK as non-root:** if EAL complains about physical addresses, add `--iova-mode=va` (mlx5 supports it). If it can't write to `/dev/hugepages`, check that mount's permissions on the host.
- **One run per interface at a time.** While a run holds an interface, a second `CCB_NET` run with the same interface fails with "interface not found". Two runs with different ports or VFs work in parallel. `ccb` and `oc` can't hold the same interface at the same time either.

### Host networking with raw packets (`CCB_RAW`)

If the bridge network doesn't work for you (DNS, VPN), `CCB_NET` isn't available, because it needs the container's own network to move interfaces into. Use this instead:

```zsh
CCB_NETWORK=host CCB_RAW=1 ccb                    # Claude Code
CCB_NETWORK=host CCB_RAW=1 ccb ./build/app ...    # a test run
```

The container shares the host's network, so your app sees `enp1s0f0np0`/`enp1s0f1np1` with their IP addresses and finds their RDMA devices. The command runs as `dev` with `CAP_NET_RAW` only, plus all `uverbs` devices, unlimited `memlock` and `/dev/hugepages`. That's enough for raw packet QPs, `ibv_create_flow` and DPDK. There is no `CAP_NET_ADMIN`, so interface settings such as MTU or promiscuous mode have to be made on the host.

**Only some ports:** `CCB_RAW` (and `CCB_RDMA`) also take a list of interfaces or RDMA devices instead of `1`. Only those ports' `uverbs` nodes are passed. Two containers at the same time, e.g. TX on one port and RX on the other:

```zsh
CCB_NETWORK=host CCB_RAW=enp1s0f0np0 ccb ./build/tx ...     # terminal 1
CCB_NETWORK=host CCB_RAW=enp1s0f1np1 ccb ./build/rx ...     # terminal 2
```

`ibv_devices` inside still lists all devices (sysfs isn't separated), but opening a device that wasn't passed fails. That doesn't limit `CAP_NET_RAW` itself: plain packet sockets (tcpdump-style) still work on every host interface.

What that means: `CAP_NET_RAW` in the host's network applies to **all** host interfaces, including your uplink and the VPN. The process, and Claude Code if it runs there, can capture and send raw traffic on any of them. Nothing is moved or restored, so there's no sudo prompt, and two runs can use the same port at the same time. Rootful engine only.

### Deliberately not included

- **`/dev/mst` and MFT (`mlxconfig`, `flint`).** These need root and raw PCI access, and would let the agent change NIC firmware settings or reflash the card. Read the temperature on the host.
- **`umad`/`issm`.** Raw management datagrams and subnet-manager access.

---

## Claude Code configuration and data

Everything Claude Code stores is in **`~/.local/share/claude-box/`** (`CLAUDE_CONFIG_DIR=/home/dev/.claude` in the container). It's created with mode 700.

| Path | Contents |
|---|---|
| `.credentials.json` | your login token |
| `.claude.json` | account, per-project folder trust, user-scope MCP servers |
| `settings.json` | your settings; create it if you want any (see below) |
| `CLAUDE.md` | your personal instructions for all projects |
| `projects/<path>/` | conversation transcripts (`*.jsonl`) and Claude's auto memory per project |
| `commands/`, `agents/`, `skills/` | your own slash commands, subagents and skills |

- **Separate from the host.** A Claude Code installed on the host uses `~/.claude` and isn't touched. To reuse your host `CLAUDE.md`, skills or agents, copy them into this folder.
- **Project files work as usual.** A repo's `CLAUDE.md`, `AGENTS.md`, `.claude/settings.json` and `.mcp.json` are in the mounted project.
- **Environment notes.** The image also has `/etc/claude-code/CLAUDE.md` (from `claude-box.md`): short facts about the container, e.g. no sudo, where CUDA is, don't push. Claude loads it in every session. Edit `claude-box.md` and rebuild to change it.
- **Sensitive.** Transcripts contain all code the agent read, and `.credentials.json` is your login. Back up and delete the folder accordingly (no container running): `tar czf claude-box-data.tgz -C ~/.local/share claude-box`.

Settings in the image (environment variables):

| Variable | Why |
|---|---|
| `DISABLE_AUTOUPDATER=1`, `DISABLE_UPDATES=1` | An update inside would be lost with the container. Update with `ccb-update` on the host (see [Maintenance](#maintenance)). |
| `CLAUDE_CONFIG_DIR=/home/dev/.claude` | Keeps `.claude.json` in the mounted folder too; otherwise the login and folder trust would be lost after every run. |

Example `~/.local/share/claude-box/settings.json`:

```json
{
  "env": { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1" }
}
```

That turns off telemetry, error reporting and feature-flag fetching. Features that need feature flags, such as Remote Control, then stop working. The model traffic itself is unaffected.

### Permissions

By default Claude Code asks before running commands and editing files, as on the host. In the container you can skip the prompts:

```zsh
ccb --dangerously-skip-permissions
```

This works because the container user isn't root (Claude Code refuses the flag as root). The container limits what the agent can reach on your machine, but not what it can send out. With internet access, text crafted to manipulate it (in a web page, an issue, a dependency's README) could make it upload project files, or the login token from `~/.claude/.credentials.json`, to any server. So:

- Use it on repositories you trust, and commit before a session.
- Middle ground: `--permission-mode acceptEdits` (edits without asking, commands still ask), or [auto mode](https://code.claude.com/docs/en/permission-modes), where a classifier reviews actions.
- Consider [blocking the LAN](#blocking-the-lan-optional).

---

## Blocking the LAN (optional)

By default the container reaches the internet **and** your LAN (other lab machines, the router), plus host services that listen on non-loopback addresses (through the bridge gateway). Services bound to `127.0.0.1` on the host, such as llama-server, are not reachable.

To allow only the internet (Docker, default iptables firewall):

```zsh
cd ~/claude-box
docker network create -o com.docker.network.bridge.name=br-claude-box claude-box
sudo cp claude-box-nolan.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-box-nolan.service
```

`ccb` uses the `claude-box` network automatically once it exists. The unit adds rules for containers on that network (the `br-claude-box` bridge):
- Rejects packets to private and link-local ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`), except DNS on port 53, so name resolution through a LAN resolver still works.
- Rejects all connections to the host itself, except DNS on port 53 (for the resolver setup in [Network problems](#network-problems-dns-proxy)).

The unit runs again whenever Docker restarts. Check:

```zsh
cd ~/projects/some-repo
ccb bash -c 'curl -sm5 -o /dev/null -w "internet: %{http_code}\n" https://pypi.org; curl -sm5 http://192.168.1.1 >/dev/null && echo "LAN REACHABLE" || echo "LAN blocked: OK"'
```

(Use a real LAN address of yours instead of `192.168.1.1`.)

Limits:
- IPv4 only. Docker networks have no IPv6 unless you enable it.
- `CCB_NET` interfaces are not affected: moving a VF into the container is meant to give it that segment.
- Docker only. Podman uses other firewall chains; this unit does nothing for it.
- To undo: `sudo systemctl disable --now claude-box-nolan.service && docker network rm claude-box`.

---

## Network problems (DNS, proxy)

Symptom: the build stops with `curl: (6) Could not resolve host: claude.ai`, or Claude Code in the container can't connect. Containers don't use the host's network setup one to one, so something that works on the host can fail inside. Compare:

```zsh
getent hosts claude.ai api.anthropic.com pypi.org      # on the host
env | grep -i _proxy                                   # does the host use a proxy?
docker run --rm ubuntu:24.04 sh -c 'cat /etc/resolv.conf; getent hosts claude.ai api.anthropic.com pypi.org'
```

`getent` prints an address per name that resolves and nothing for one that doesn't.

**1. The host resolves the names, the container doesn't, and there's no proxy.** On Ubuntu, the host asks systemd-resolved (`127.0.0.53`), which containers can't reach. Docker therefore gives containers the upstream servers from `/run/systemd/resolve/resolv.conf` and they ask those directly, without resolved's settings: DNS-over-TLS, per-interface DNS (e.g. a VPN's), its cache. Let containers use resolved itself:

```zsh
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListenerExtra=172.17.0.1\n' | sudo tee /etc/systemd/resolved.conf.d/docker.conf
sudo systemctl restart systemd-resolved
ss -lun | grep 172.17.0.1:53                           # resolved now also listens on docker0
```

Then add `"dns": ["172.17.0.1"]` to `/etc/docker/daemon.json`. That file may already contain the `"runtimes"` entry from `nvidia-ctk`, so add the key and keep the rest, e.g.:

```json
{
  "runtimes": { "nvidia": { "args": [], "path": "nvidia-container-runtime" } },
  "dns": ["172.17.0.1"]
}
```

```zsh
sudo systemctl restart docker
docker run --rm ubuntu:24.04 getent hosts claude.ai api.anthropic.com   # must print addresses now
```

With ufw enabled, also allow the queries: `sudo ufw allow in on docker0 to any port 53` and the same for `br-claude-box` if you use the LAN block.

If containers still resolve nothing (`/etc/resolv.conf` inside says `nameserver 172.17.0.1`, but `getent` prints nothing), no answer comes from `172.17.0.1:53`:

```zsh
readlink -f /etc/resolv.conf        # /run/systemd/resolve/stub-resolv.conf = the host uses resolved
ss -lnup | grep ':53 '              # must include 172.17.0.1:53
dig +short @172.17.0.1 claude.ai    # from the host (package bind9-dnsutils)
```

| Result | Cause and fix |
|---|---|
| `/etc/resolv.conf` isn't resolved's (e.g. `nameserver 127.0.0.1` or `127.0.1.1`) | Another local resolver (dnsmasq, dnscrypt-proxy, a VPN client) answers the host, and resolved's listener doesn't help. Make that resolver listen on `172.17.0.1` too, e.g. dnsmasq: `listen-address=127.0.0.1,172.17.0.1` |
| No `172.17.0.1:53` in `ss` | resolved didn't load the drop-in: check that `/etc/systemd/resolved.conf.d/docker.conf` contains exactly the two lines, `sudo systemctl restart systemd-resolved`, and see `journalctl -u systemd-resolved -b` |
| `dig` answers, containers still don't | A firewall drops traffic from `docker0` to the host: the ufw rule above, or find the rule with `sudo iptables -S INPUT` / `sudo nft list ruleset` |

To get just the build through in the meantime, remove `"dns"` from `daemon.json` again, restart Docker, and build with `docker build --network host ...`. The build steps then use the host's own resolver. That doesn't work while `"dns"` is set, because Docker gives host-network builds that server too. And it doesn't help `ccb`, whose containers need working DNS.

**2. The host uses a proxy** (`https_proxy` is set). Docker doesn't pass it on. For the build: `docker build --network host --build-arg https_proxy=$https_proxy --build-arg HTTPS_PROXY=$https_proxy ...`. Docker doesn't store these proxy arguments in the image. At runtime, the proxy must be reachable from the container: `127.0.0.1` inside the container is the container itself, so the proxy has to listen on `172.17.0.1` (or a LAN address), and you start with `HTTPS_PROXY=http://172.17.0.1:<port> https_proxy=http://172.17.0.1:<port> CCB_ENV="HTTPS_PROXY https_proxy" ccb`. Claude Code and curl/pip then go through it. The LAN block rejects connections to the host, so it doesn't combine with a proxy on the host.

**3. The host can't resolve them either.** Then your network or DNS provider blocks or doesn't answer for them, and no Docker setting helps. Claude Code needs `claude.ai` (login) and `api.anthropic.com` (the model) reachable, and it is only available in [Anthropic's supported countries](https://www.anthropic.com/supported-countries).

---

## Maintenance

**Update Claude Code** without rebuilding the image:

```zsh
ccb-update              # newest release
ccb-update stable       # newest of the stable channel (about a week older, skips bad releases)
ccb-update 2.1.281      # a specific version, also to go back
```

`ccb-update` downloads the native Linux binary on the host (one file, about 230 MB, with a progress bar) from Anthropic's release bucket, the same files the official installer uses, and checks its SHA-256 against the release manifest. It stores Claude Code in `~/.local/share/claude-box-cli` on the host and keeps the active version plus the previous one. The next `ccb` start mounts that folder read-only and uses it instead of the version built into the image. Running containers keep their version until you restart them. Login, settings and conversations are not affected.

To go back to the image's built-in version: `rm -rf ~/.local/share/claude-box-cli`. The image's version (`CLAUDE_CODE_VERSION` in the Dockerfile) only matters as that fallback, so there's no need to rebuild for updates.

**Add tools for the agent** (compilers, libraries, clangd, Node.js for MCP servers, …). Add them to the `apt-get install` line in the Dockerfile and rebuild. Python packages go into `requirements.txt`.

**Remove old images:** `docker image prune`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ccb: command not found` | `~/bin` not in PATH: see step 3; run `rehash` in already-open zsh terminals |
| `permission denied ... docker.sock` | `sudo usermod -aG docker $USER`, then log out/in (or `newgrp docker`) |
| Build: `curl: (6) Could not resolve host: claude.ai` | The build container can't resolve names the host can: see [Network problems](#network-problems-dns-proxy) |
| Build fails later in the Claude Code step | The version doesn't exist: check `CLAUDE_CODE_VERSION` |
| Claude Code in the container can't connect (`Unable to connect to API`, `ENOTFOUND`) | Same DNS/proxy cause as above: [Network problems](#network-problems-dns-proxy) |
| Login: the browser never returns to Claude Code | Expected in a container: copy the code the browser shows and paste it at `Paste code here if prompted` |
| Asked to log in on every run | `~/.local/share/claude-box` isn't writable, or you set `CCB_DATA` differently between runs |
| `Login expired · Please run /login` | Run `/login` inside Claude Code |
| `ccb: refusing to mount ...: it contains your home folder` | Run `ccb` from inside a project folder, not from `~` |
| Claude Code wants to `sudo apt install ...` | Not possible in the container: add the package to the Dockerfile and rebuild |
| `pip install` fails with `Read-only file system` | You're using `CCB_VENV` (mounted read-only): install into that venv on the host |
| `git push` fails inside | Expected: no credentials in the container. Push from the host |
| Files created by the agent owned by another user | Rebuild with `--build-arg UID=$(id -u) --build-arg GID=$(id -g)`; with rootless Podman use `CCB_ENGINE=podman` |
| `ccb -p ...` pauses 3 s | Add `< /dev/null` |
| Colors or keys look wrong, `terminal is not fully functional` | `ccb` passes your `TERM`, and the image has terminfo for alacritty, wezterm, foot and kitty. For other terminals: `TERM=xterm-256color ccb` |
| `ccb: CCB_GPU set, but the NVIDIA Container Toolkit is not installed` | Install it: [GPU and CUDA](#host-setup-once) |
| `could not select device driver "" with capabilities: [[gpu]]` | Same: toolkit missing, or Docker not restarted after installing it |
| Podman: `unresolvable CDI devices nvidia.com/gpu=all` | `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (again after driver updates) |
| `nvidia-smi` works, `nvcc: command not found` | No toolkit mounted: `/usr/local/cuda` missing on the host; set `CCB_CUDA=/usr/local/cuda-X.Y` |
| `CUDA driver version is insufficient for CUDA runtime version` | The toolkit is newer than the host driver supports: use an older `CCB_CUDA`, or update the driver |
| CUDA `out of memory` right away | llama-server (or something else) holds the VRAM: `nvidia-smi` on the host |
| `ncu`: `ERR_NVGPUCTRPERM` | See Profilers in [Things to know](#things-to-know) |
| `ccb: CCB_RDMA set, but no /dev/infiniband/uverbs*` | RDMA driver not loaded on the host: `sudo modprobe mlx5_ib`, then `ibv_devices` |
| `ibv_devices` empty inside the container | `rdma system show` says `exclusive`: set it to `shared` on the host |
| `ibv_reg_mr` fails with ENOMEM/EPERM | Started without `CCB_RDMA=1`, so memlock is limited. With rootless Podman, raise the user's `memlock` hard limit in `/etc/security/limits.conf` first |
| `Permission denied` opening `/dev/infiniband/uverbs0` | Host device mode isn't `0666`: see [Mellanox / RDMA](#one-time-host-check) |
| Raw packet QP / `ibv_create_flow` / DPDK fails with `EPERM` | Started with `CCB_RDMA=1`; packet RX/TX needs `CCB_NET` |
| `CCB_NET`: `'<name>' is a physical port, not an SR-IOV VF` | Use the VF's netdev (`ip -br link` after creating VFs), or `CCB_NET_ALLOW_PF=1` |
| `CCB_NET`: `carries the host's default route` | That port is the host's uplink; use the other port or a VF |
| `CCB_NET`: `interface ... not found on host` | Typo, VFs not created after reboot, or another run holds it (`docker ps --filter name=ccb-net- --filter name=oc-net-`) |
| `CCB_NET`: `netns mode is 'exclusive'` | `sudo rdma system set netns shared` |
| Port has no IP address after a run | The restore failed (sudo prompt not answered, or `kill -9`). Re-apply: `networkctl reconfigure <port>` or `nmcli device connect <port>` |
| VF missing from the host after a crash | The container outlived the wrapper: `docker rm -f $(docker ps -aq --filter name=ccb-net-)`; the VF returns |
| LAN still reachable with the unit enabled | The container isn't on the `claude-box` network (`docker network ls`), or the host uses Docker's nftables backend |

---

## Security notes

- **Sent to Anthropic:** every file and command output the agent reads. That's inherent to Claude Code; use the box only for repositories allowed to go there.
- **Protected by the container:** your files outside the mounted folders (`~/.ssh`, credentials, other repos, the host's Claude Code login), host processes, and the system. The agent runs as your UID without root, capabilities or `sudo` (`no-new-privileges`).
- **Not protected:** the project and `CCB_RW` folders are writable (commit before a session), and the agent's own login token is inside the container. With internet access the agent can download and upload anything, and without the [LAN block](#blocking-the-lan-optional) it also reaches your LAN.
- Never mount `$HOME`, `~/.ssh`, credential files or `/var/run/docker.sock` into the container. `ccb` refuses the home folder itself.
- With `CCB_GPU`, the agent can use all memory of the passed GPUs. It can't change driver settings (that needs root).
- With `CCB_RDMA=1`, the agent can send RDMA traffic to other RDMA machines on your fabric. With `CCB_NET`, it can send arbitrary Ethernet frames on that segment. `CCB_NET` defaults to `bash`: run hardware tests yourself, and start Claude Code there (`CCB_NET=... ccb claude`) only when it needs the port.

## Notes

This was tested with Docker 29 on Ubuntu 24.04, with an image built from this Dockerfile (`WITH_GUI=0`; the Qt part is unchanged from `opencode-offline`) on a locally made Ubuntu 24.04 base. My test environment couldn't reach `claude.ai`, so the Claude Code install step was replaced by the same 2.1.273 Linux binary taken from npm. **The install step itself (`install.sh <version>`) is untested; your first `docker build` is that test.**

Verified with the real container:
- `claude --version` and `claude doctor` run as `dev` (your UID), with updates disabled and bundled search.
- Claude Code writes `.claude.json` and its other files into the mounted data folder, owned by your UID.
- `claude -p` against a mock API server: works as `dev`, including `--dangerously-skip-permissions`, which Claude Code refuses as root. `< /dev/null` skips the 3 s stdin wait. The requests contain the environment notes from `/etc/claude-code/CLAUDE.md`.
- The project at the same path, commits with your git name and email, files owned by you. A worktree can commit through its mounted object store.
- pandas 3.0.6 next to the pinned packages: the whole `requirements.txt` resolves in a fresh venv (numpy stays 1.26.4), `pip check` is clean, and pandas runs.
- `pip install` into `/opt/venv` during a run. A host venv is used read-only (`pip install` into it fails with `Read-only file system`), and a venv made with a Python the image lacks is refused.
- The CUDA mount, with a stand-in toolkit laid out like the real one (`lib64 -> targets/x86_64-linux/lib`): mounted read-only at both paths, `nvcc` on `PATH`, `CUDACXX` and `LD_LIBRARY_PATH` set, also together with `CCB_VENV`.
- The LAN block, with a stand-in LAN host in its own network namespace. Before the rules, the container reached it and a web server on the host. With the rules, both were rejected, while port 53 on the LAN host and on the host, DNS and the internet (pypi.org) still worked, and containers on Docker's default bridge were unaffected. Starting the unit twice doesn't duplicate rules, and stopping it removes them.
- `CCB_NET`, with a veth stand-in VF and a fake RDMA device node: the interface moved in next to the container's own network, with its IP address. The command ran as `dev` with exactly `NET_RAW` + `NET_ADMIN` and could still reach the internet. The exit code passed through, the interface came back to the host with its address, and the container was removed. My environment doesn't allow unlimited `memlock`, so that run was made without it.

Checked only in dry runs (a stand-in `docker` that prints its arguments): the `--gpus` and CDI arguments, the GPU and toolkit checks, the refusal of `~` and its parents, a dotfiles repo at `~`, a submodule's object store, `CCB_ENV`, and the network choice.

Not tested: a real GPU and CUDA (no GPU in the test environment), a real login, and Mellanox hardware.
