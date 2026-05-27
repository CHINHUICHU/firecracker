# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Firecracker is a KVM-based Virtual Machine Monitor (VMM) for running lightweight microVMs. Each Firecracker process encapsulates exactly one microVM and exposes an HTTP API over a Unix socket. The primary working directory for this session is `src/vmm/src/devices/virtio/vsock`, which implements the virtio-vsock device.

## Build & Development Commands

All standard development tasks run through `tools/devtool`, which wraps `cargo` inside a Docker dev container. Requires Docker and a Linux host with KVM (`/dev/kvm`).

```bash
# Build debug binaries (output: build/cargo_target/<arch>-unknown-linux-musl/debug/)
tools/devtool build

# Build release binaries
tools/devtool build --release

# Auto-format Rust, markdown, and Python (run before committing)
tools/devtool fmt

# Lint and style checks (what CI runs)
tools/devtool checkstyle
tools/devtool checkbuild --all

# Run all integration tests (requires KVM + Docker)
tools/devtool -y test

# Run a specific integration test file
tools/devtool -y test -- integration_tests/functional/test_vsock.py

# Run a single integration test
tools/devtool -y test -- integration_tests/functional/test_vsock.py::test_vsock_any

# Open an interactive shell in the dev container
tools/devtool -y shell --privileged
```

Without Docker, cargo commands work directly for unit tests (no KVM needed):

```bash
# Run unit tests for the vmm crate
cargo test --package vmm

# Run a single test by name
cargo test --package vmm -- vsock::packet::tests::test_vsock_packet_hdr_len

# Run Rust integration tests only
cargo test --test integration_tests --all

# Run clippy (matches CI rules)
cargo clippy --all
```

### Pre-commit Hook

```bash
cat >> .git/hooks/pre-commit << 'EOF'
./tools/devtool checkstyle || exit 1
./tools/devtool checkbuild --all || exit 1
EOF
```

## Kani Formal Verification (Group 4 Project)

This fork adds Kani proof harnesses for the vsock packet parser. Requires Rust 1.95.0 and Kani 0.67.0.

```bash
# One-time setup
sudo apt-get install -y libclang-dev
cargo install --locked kani-verifier --version 0.67.0
cargo kani setup

# Run a single harness
cargo kani --package vmm --harness verify_header_all_fields_roundtrip

# Run all eight vsock harnesses
cargo kani --package vmm \
  --harness verify_header_all_fields_roundtrip \
  --harness verify_set_flag_is_or \
  --harness verify_pkt_hdr_size_constant \
  --harness verify_tx_buf_size_no_underflow \
  --harness verify_write_from_offset_to_nonzero_count_no_overflow \
  --harness verify_rx_buf_size_no_underflow \
  --harness verify_read_at_offset_from_nonzero_count_no_overflow \
  --harness verify_write_zero_count_overflow_finding
```

Expected result: `7 successfully verified, 1 failure` — the last harness intentionally documents a latent integer-overflow bug (see `KANI_VERIFICATION.md` §6 for details and the suggested fix).

## Architecture

### Process Model

Each Firecracker process runs three thread types:
- **API thread** — HTTP server over a Unix socket; handles all pre-boot configuration and runtime control-plane requests via `VmmAction` enum (`src/vmm/src/rpc_interface.rs`).
- **VMM thread** — device emulation, MMIO/PIO handling, event loop (`src/vmm/src/`).
- **vCPU thread(s)** — one per guest CPU, run the `KVM_RUN` loop.

### Crate Layout (`src/`)

| Crate | Purpose |
|---|---|
| `firecracker` | Binary entry point, HTTP API server, OpenAPI schema |
| `vmm` | Core VMM: devices, vstate (KVM wrappers), builder, snapshot, seccomp |
| `jailer` | Production sandbox: cgroup/namespace isolation before exec |
| `seccompiler` | Compiles seccomp BPF filter policies |
| `utils` | Shared utilities (epoll, rate limiter, etc.) |
| `snapshot-editor` | Offline snapshot inspection/modification |

### Virtio Device Stack (`src/vmm/src/devices/virtio/`)

All virtio devices share a common pattern: `device.rs` (VirtioDevice trait impl), `event_handler.rs` (epoll callbacks), `queue.rs` (descriptor chain processing), `persist.rs` (snapshot state). The transport layer is either MMIO (default) or PCI (enabled via `--enable-pci`).

### Vsock Device (`src/vmm/src/devices/virtio/vsock/`)

Implements virtio-vsock without vhost — Firecracker mediates between guest AF_VSOCK and host AF_UNIX sockets entirely in userspace.

Key modules:

- **`packet.rs`** — `VsockPacketTx` / `VsockPacketRx`: zero-copy wrappers over virtio descriptor chains. Packet header is a packed C struct (`VsockPacketHeader`). The Kani harnesses target this file.
- **`device.rs`** / **`event_handler.rs`** — virtio device model; drives RX/TX queues.
- **`unix/muxer.rs`** (`VsockMuxer` = `VsockUnixBackend`) — connection multiplexer; maps guest vsock ports to host AF_UNIX socket paths (`<uds_path>_<port>`). Max 1023 simultaneous connections.
- **`csm/connection.rs`** (`VsockConnection`) — per-connection state machine with states: `LocalInit`, `PeerInit`, `Established`, `LocalClosed`, `PeerClosed`, `Killed`.
- **`iovec.rs`** / **`iov_deque.rs`** (parent module) — scatter-gather I/O over guest memory; `IoVecBuffer` / `IoVecBufferMut` wrap `libc::iovec` slices for `readv`/`writev`.

Connection initiation directions:
- **Host → Guest**: connect to `<uds_path>`, send `"CONNECT <port>\n"`, receive `"OK <host_port>\n"`.
- **Guest → Host**: connect AF_VSOCK to CID 2 and port; Firecracker connects to `<uds_path>_<port>` on host.

### Snapshot / Restore

Implemented via `src/vmm/src/persist.rs` and per-device `persist.rs` files. The `VmmAction::CreateSnapshot` / `LoadSnapshot` actions pause the VM, serialize state via `serde`, and write versioned binary blobs. Vsock snapshot support is limited (connections reset on restore).

## Code Standards

- **`unsafe` blocks** require a `// SAFETY:` comment listing all upheld invariants, plus a `// JUSTIFICATION:` if safe alternatives exist.
- **No `unwrap()`** without a comment explaining why it cannot panic; prefer `.map_err(|_| ...)` or `?`.
- All public functions must be documented.
- Each logical change in a PR must be a separate commit, signed off with `Signed-off-by:` (`git commit -s`).
- Line width: 100 characters (enforced by `rustfmt.toml`).
- Imports grouped: `std` → external crates → internal crates (enforced by `rustfmt.toml`).
