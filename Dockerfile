FROM ubuntu:24.04

# Tools the agent needs. Add your own toolchain / libraries here.
# ncurses-term, kitty-terminfo: terminfo for alacritty/wezterm/foot/kitty, since ccb passes your TERM in.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep tini less procps jq file unzip xz-utils zstd \
      ncurses-term kitty-terminfo \
      build-essential cmake ninja-build gdb python3 python3-venv python3-dev \
 && rm -rf /var/lib/apt/lists/*

# RDMA userspace for Mellanox/NVIDIA NICs (used with CCB_RDMA=1 / CCB_NET).
# iproute2 brings the VF up inside the container; util-linux provides setpriv, which
# CCB_NET uses to drop from root to dev while keeping only NET_RAW + NET_ADMIN.
# These match the host's inbox kernel driver. If the host runs MLNX_OFED / DOCA-OFED,
# install the same-version userspace from NVIDIA's repo here instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
      rdma-core ibverbs-providers ibverbs-utils rdmacm-utils \
      libibverbs-dev librdmacm-dev perftest infiniband-diags iproute2 \
      util-linux \
 && rm -rf /var/lib/apt/lists/*

# No CUDA in the image: the driver comes from the host through the NVIDIA Container Toolkit,
# and ccb mounts the host's CUDA toolkit (/usr/local/cuda) read-only when CCB_GPU is set.

# ubuntu:24.04 ships user "ubuntu" with UID 1000 - replace it with "dev" using your UID/GID
ARG UID=1000
ARG GID=1000
RUN userdel -r ubuntu 2>/dev/null || true \
 && (getent group ${GID} >/dev/null || groupadd -g ${GID} dev) \
 && useradd -m -u ${UID} -g ${GID} -s /bin/bash dev

# Standard Python venv (same requirement files as opencode-offline).
#   WITH_GUI=1 (default): also Qt (PyQt5/6, PySide6, pyqtgraph, pyfda, mplcursors), ~1.1 GB,
#   plus the system libraries Qt needs to run offscreen. WITH_GUI=0 skips all of it.
# The venv belongs to dev, so the agent can `pip install` extra packages during a run.
# Those are gone when the run ends; permanent ones go into requirements.txt.
ARG WITH_GUI=1
RUN if [ "$WITH_GUI" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libegl1 libfontconfig1 libfreetype6 libdbus-1-3 libglib2.0-0t64 \
        libxkbcommon0 libx11-6 libxext6 libgssapi-krb5-2 libpng16-16t64 fonts-dejavu-core \
      && rm -rf /var/lib/apt/lists/*; \
    fi \
 && install -d -o dev -g dev /opt/venv
COPY requirements.txt requirements-gui.txt /opt/venv-req/
USER dev
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && if [ "$WITH_GUI" = "1" ]; then gui="-r /opt/venv-req/requirements-gui.txt"; else gui=""; fi \
 && /opt/venv/bin/pip install --no-cache-dir -r /opt/venv-req/requirements.txt $gui \
 && /opt/venv/bin/pip check

# More tools. Its own layer after the venv, so adding packages here doesn't re-download Python.
#   gcc-14/g++-14 next to the default GCC 13 (use CC=gcc-14 CXX=g++-14 or -DCMAKE_CXX_COMPILER=g++-14);
#   liburing, GoogleTest (libs + CMake config), NIC/PCI/NUMA tools, pkg-config;
#   podman: usable for images and remote access, but it can't start containers inside this one
#   (no privileges here; see README).
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-14 g++-14 liburing-dev libgtest-dev libgmock-dev \
      ethtool pciutils numactl libnuma-dev pkg-config \
      podman \
 && rm -rf /var/lib/apt/lists/*

# Network tools. Capturing needs CAP_NET_RAW, i.e. CCB_RAW or CCB_NET (see README).
#   tshark/tcpdump/termshark: capture + dissect (MPEG-TS, DVB, RoCE included); libpcap here can also
#   capture on RDMA devices (tcpdump -i mlx5_0), which sees kernel-bypass traffic too.
#   tcpreplay/netsniff-ng (trafgen): replay pcaps / generate packets; iperf3, netcat, socat,
#   ping/arping/traceroute/mtr, dig, nmap, lsof, strace for everything else.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tshark tcpdump termshark tcpreplay netsniff-ng \
      iperf3 netcat-openbsd socat iputils-ping iputils-arping traceroute mtr-tiny \
      dnsutils nmap lsof strace \
 && rm -rf /var/lib/apt/lists/*
USER dev

# Claude Code, native build, pinned. Last step: an update only re-runs this layer.
# Version: a number (see the changelog), or "stable" / "latest" for the newest one of that channel.
# Installed to ~/.local/bin/claude -> ~/.local/share/claude/versions/<version>.
# The build-time ~/.claude is removed: at runtime ccb mounts your data folder there.
ENV HOME=/home/dev
ARG CLAUDE_CODE_VERSION=2.1.273
RUN curl -fsSL -o /tmp/install.sh https://claude.ai/install.sh \
 && bash /tmp/install.sh "${CLAUDE_CODE_VERSION}" \
 && rm -rf /tmp/install.sh /home/dev/.claude /home/dev/.claude.json \
 && mkdir -m 700 /home/dev/.claude \
 && /home/dev/.local/bin/claude --version

# Tells Claude about this environment in every session (managed CLAUDE.md, always loaded).
COPY claude-box.md /etc/claude-code/CLAUDE.md

# Set after the install (DISABLE_UPDATES would block it). Update Claude Code by rebuilding.
# CLAUDE_CONFIG_DIR puts .claude.json (login, per-project trust) inside the mounted folder too.
# No display: matplotlib writes files, Qt renders offscreen.
ENV CLAUDE_CONFIG_DIR=/home/dev/.claude \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_UPDATES=1 \
    LANG=C.UTF-8 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    MPLBACKEND=Agg \
    QT_QPA_PLATFORM=offscreen

WORKDIR /home/dev
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["claude"]
