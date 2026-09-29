# claude-box environment

You are running inside the claude-box container (Ubuntu 24.04), not directly on the user's host.

- The user built and maintains this image. Claude Code can't update itself inside; the user updates it on the host with `ccb-update` (newest), `ccb-update stable` or `ccb-update X.Y.Z`, then restarts ccb. Tell them that instead of trying to update inside.
- User `dev`, no root: `sudo` and `apt-get install` don't work. If a system package is missing, say so; it has to be added to the image's Dockerfile.
- Python: the venv /opt/venv is active. `pip install` into it works, but only until the container exits; name packages that should go into requirements.txt permanently.
- Only the project (at the same path as on the host) and folders the user added are mounted. Files you create anywhere else are lost when the container exits.
- GPU and CUDA only when the user started with CCB_GPU; check with `nvidia-smi`. The CUDA toolkit is the host's, read-only, at /usr/local/cuda (nvcc on PATH, CUDACXX set).
- Mellanox RDMA devices only with CCB_RDMA, CCB_RAW or CCB_NET (raw packet QPs/DPDK need CCB_RAW or CCB_NET); check with `ibv_devices`. With CCB_NET, $CCB_NET and $CCB_IBDEV list the interfaces and their RDMA devices.
- No SSH keys or git credentials here: commit, but don't push; the user pushes from the host.
- Compilers: GCC 13 is the default; gcc-14/g++-14 are installed (CC=gcc-14 CXX=g++-14). Also liburing, GoogleTest/GMock (CMake: find_package(GTest)), libnuma, pkg-config, ethtool, lspci, numactl. io_uring works if the user installed the box's seccomp profile.
- Network tools: tshark, tcpdump, termshark, tcpreplay/tcprewrite, trafgen/mausezahn, iperf3, nc, socat, ping/arping/traceroute/mtr, dig, nmap, lsof, strace. Capturing live traffic needs CAP_NET_RAW (only with CCB_RAW or CCB_NET); reading and dissecting pcap files works always (tshark -d udp.port==N,mp2t for MPEG-TS). tcpdump/tshark -i mlx5_0 captures on the RDMA device, including kernel-bypass traffic.
- podman is installed but can't start or build containers inside this container (no privileges). Ask the user to run container steps on the host.
- No display: matplotlib uses the Agg backend, Qt runs offscreen.
