# Formal Verification of the Vsock Packet Parser — Group 4

This document covers the environment setup, code changes, and instructions for running the Kani
proof harness written for the Firecracker Vsock packet parser, addressing Objective 1 of the
Group 4 project proposal (baseline verification of the packet parsing logic).

---

## 1. Environment Setup

### 1.1 Install Rust

The project requires Rust **1.95.0** (pinned in `rust-toolchain.toml`).

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
source "$HOME/.cargo/env"
```

### 1.2 Install libclang (required by userfaultfd-sys bindgen)

```bash
sudo apt-get install -y libclang-dev
```

### 1.3 Install Kani

The Firecracker dev container uses Kani **0.67.0**. Install the same version:

```bash
cargo install --locked kani-verifier --version 0.67.0
cargo kani setup          # downloads CBMC and the nightly toolchain (~once)
cargo kani --version      # should print cargo-kani 0.67.0
```

---

## 2. What is verified

`VsockPacketTx::parse` is the entry point where guest-controlled bytes are turned into a vsock
packet. It is a direct attack surface: a malicious guest fully controls the 44-byte header and
the descriptor-chain geometry. The harness proves the header-validation logic is **panic-free**
for every possible input and that, on success, it establishes the invariants the rest of the
device model depends on.

| Item | Detail |
|---|---|
| Harness | `verify_tx_parse_header_no_panic` |
| Location | `src/vmm/src/devices/virtio/vsock/packet.rs` → `#[cfg(kani)] mod verification` |
| Target | `VsockPacketTx::parse_header` (the validation half of `parse`) |
| Property 1 | **No panic / no integer overflow** on any path. In particular the `self.buffer.len() - VSOCK_PKT_HDR_SIZE` subtraction never underflows. |
| Property 2 | On `Ok`, `buffer.len() >= VSOCK_PKT_HDR_SIZE` (so `buf_size()` cannot underflow downstream). |
| Property 3 | On `Ok`, `hdr.len() <= MAX_PKT_BUF_SIZE` **and** `hdr.len() <= buf_size()` (payload length validated against both the protocol cap and the real buffer capacity). |

---

## 3. Code Changes

### 3.1 `src/vmm/src/devices/virtio/iovec.rs`

Added a `#[cfg(kani)]` constructor so harnesses in other modules can build an `IoVecBuffer` with
a symbolic length but no backing memory:

```rust
#[cfg(kani)]
impl IoVecBuffer {
    pub(crate) fn with_len(len: u32) -> Self {
        Self { vecs: Vec::new(), len }
    }
}
```

`IoVecBuffer` has private fields, so it cannot be constructed from `packet.rs` directly. This
buffer reports an arbitrary `len()` but holds no iovecs — which is exactly what we want, because
the header read is **stubbed** (see §4) and never touches real memory.

### 3.2 `src/vmm/src/devices/virtio/vsock/packet.rs`

**Refactor (behavior-preserving):** `VsockPacketTx::parse` was split into two methods:

```rust
pub fn parse(&mut self, mem, chain) -> Result<(), VsockError> {
    unsafe { self.buffer.load_descriptor_chain(mem, chain)? };  // FFI/mmap — not verifiable
    self.parse_header()                                          // pure validation — verified
}

fn parse_header(&mut self) -> Result<(), VsockError> {
    // read 44-byte header, then:
    //   - reject hdr.len > MAX_PKT_BUF_SIZE
    //   - reject hdr.len > buffer.len() - VSOCK_PKT_HDR_SIZE   ← underflow concern
    //   ...
}
```

`parse()` behaves identically to before. The split exists so the validation arithmetic can be
verified **without** `load_descriptor_chain`, which performs FFI/`mmap` work Kani cannot model.

**Harness + stub:** a `#[cfg(kani)] mod verification` block containing the stub and the proof.

---

## 4. Why the stub is necessary

This is the central design decision, so it is worth explaining in full.

### 4.1 What `parse_header` does internally

The first thing `parse_header` does is copy the 44 header bytes out of the buffer:

```rust
self.buffer.read_exact_volatile_at(hdr.as_mut_slice(), 0)
```

`IoVecBuffer` is a **scatter-gather** buffer: the guest's packet may be split across an arbitrary
number of descriptors, each pointing at an arbitrary (and possibly overlapping) region of guest
memory. `read_exact_volatile_at` walks those regions and performs a **byte-by-byte volatile copy**
through `vm_memory`'s `copy_slice_volatile` / `PtrGuard` machinery.

### 4.2 The problem: running the real copy is intractable AND off-target

We first tried a harness that built a real arbitrary buffer and called `parse_header` without any
stub. The result:

```
VERIFICATION:- FAILED   (Verification Time: 1149 s ≈ 19 min)
Failed Checks: unwinding assertion loop 0
  in vm_memory::volatile_memory::copy_slice_impl::copy_slice_volatile
** 1 of 1104 failed (1103 undetermined)
```

Two things went wrong, and both matter:

1. **Intractable.** The proof spent 19 minutes and still died on an *unwinding assertion* inside
   the byte-copy loop. Modelling an arbitrary-length copy over arbitrary, possibly-overlapping
   pointers explodes the state space. The `1103 undetermined` checks are all pointer-dereference
   obligations downstream of the cut-short unwind.

2. **Off-target.** Because the proof never got past the copy loop, **`parse_header`'s validation
   logic — the thing we actually want to verify — was never reached.** All the effort went into
   re-proving the memory safety of a generic copy primitive.

### 4.3 The fix: stub the I/O primitive, verify the real logic

The memory safety of `read_exact_volatile_at` is **not our concern here** — it is already the
subject of the dedicated `iovec.rs` harnesses (`verify_read_from_iovec`, `verify_write_to_iovec`).
So we replace it with a stub that reproduces only its observable **contract**:

```rust
#[kani::stub(IoVecBuffer::read_exact_volatile_at, stubs::read_exact_volatile_at)]
```

```rust
pub fn read_exact_volatile_at(this: &IoVecBuffer, buf: &mut [u8], offset: usize)
    -> Result<(), VolErr>
{
    let buf_len = this.len() as usize;
    if offset < buf_len {
        let available = buf_len - offset;
        if available >= buf.len() {
            for byte in buf.iter_mut() { *byte = kani::any(); } // arbitrary guest bytes
            Ok(())
        } else {
            Err(VolErr::PartialBuffer { expected: buf.len(), completed: available })
        }
    } else {
        Err(VolErr::OutOfBounds { addr: offset })
    }
}
```

This mirrors the real method's three outcomes exactly (`Ok` / `PartialBuffer` / `OutOfBounds`),
fills the header with **arbitrary** bytes (so `hdr.len`, `op`, every field is unconstrained), and
contains no pointer machinery. Verification time drops from 19 minutes (failing) to **~8 seconds
(passing)**.

### 4.4 Why this is sound, and what it assumes

- **The logic under test is real code.** The harness calls the production `parse_header`; the
  `MAX_PKT_BUF_SIZE` check, the `buffer.len() - 44` subtraction, and the capacity check are all
  the genuine implementation, not a re-modelled copy. This is the key difference from a harness
  that merely re-implements the logic it claims to check.
- **It assumes the stub matches the contract.** Stubbing means we *trust* that
  `read_exact_volatile_at` behaves as the stub describes. That assumption is discharged
  separately by the `iovec.rs` harnesses, which verify the primitive itself. The labor is
  divided, not skipped.
- **This is the project's own established pattern.** Firecracker's existing
  `verify_write_to_iovec` harness uses `#[kani::stub(IovDeque::push_back, stubs::push_back)]` for
  the same reason: to replace an FFI/memory primitive that Kani cannot model so the proof can
  focus on the logic of interest.

---

## 5. Running the Verification

The stub attribute requires Kani's unstable `stubbing` feature, so the `-Z` flags are
**mandatory** — a plain `cargo kani` will fail to compile with
*"Using the stub attribute requires activating the unstable `stubbing` feature."*

```bash
export PATH="$HOME/.cargo/bin:$PATH"

cargo kani \
  -Z unstable-options -Z stubbing -Z function-contracts -Z restrict-vtable \
  --package vmm \
  --harness verify_tx_parse_header_no_panic
```

These are the same flags the repository's CI uses (see
`tests/integration_tests/test_kani.py`), which runs all harnesses across the workspace with
`-Z stubbing` enabled.

---

## 6. Result

```
SUMMARY:
 ** 0 of 424 failed (6 unreachable)

VERIFICATION:- SUCCESSFUL
Verification Time: 8.302143 s
Complete - 1 successfully verified harness, 0 failures, 1 total.
```

The Vsock TX header parser is proven free of panics and integer over/underflow for every
guest-supplied header and buffer length, and is shown to uphold the buffer-size and
payload-length invariants its callers rely on.
