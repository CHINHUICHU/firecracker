#import "@preview/typslides:1.3.3": *

// Project configuration
#show: typslides.with(
  ratio: "16-9",
  theme: "bluey",
  font: "Fira Sans",
  font-size: 20pt,
  link-style: "color",
  show-progress: true,
)

// The front slide is the first slide of your presentation
#front-slide(
  title: "This is a sample presentation",
  subtitle: [Using _typslides_],
  authors: "A. Manjavacas",
  info: [#link("https://github.com/manjavacas/typslides")],
)

// Custom outline
#table-of-contents()

// Introduction
#title-slide[
  Introduction
  #text(size: 18pt, fill: gray)[
    - Firecracker
    - Formal Verification
  ]
]

#slide(title: "firecracker")[
  
]

#slide(title: "vsock")[
  
]


// Approach
#title-slide[
  Approach
]

#slide(title: "Approach: Target Selection")[
  - *Vsock Packet Parser*: A high-risk attack surface where the guest fully controls the 44-byte header and descriptor geometry.
  - *Goal*: Move from "Defensive Runtime Checks" to "Proven Mathematical Safety" using formal verification.
  - *Tool*: Kani Rust Verifier (Bounded Model Checking).
  - *Scope*: Systematically verify the entire Vsock data path (`packet.rs`), buffering (`txbuf.rs`), and event handling (`event_handler.rs`).
]

#slide(title: "Approach: Refactoring for Verifiability")[
  - *The Challenge*: `VsockPacketTx::parse` mixes FFI/mmap logic (intractable for Kani) with validation (verifiable).
  - *The Solution*: Refactored `parse` into two distinct steps:
    1. #underline[FFI Step]: `load_descriptor_chain` (Memory I/O).
    2. #underline[Pure Step]: `parse_header` (Validation Logic).
  - *Benefit*: Allows proof harnesses to target the validation arithmetic in isolation.
]

#slide(title: "Approach: Contract-Based Stubbing")[
  - *Stubbing*: Replaced complex scatter-gather I/O (`read_exact_volatile_at`) with a simplified mathematical contract.
  - *Focus*: Proving the *arithmetic* of the header validation, not the memory-safety of the entire `vm-memory` crate.
  - *Performance*: Verification time dropped from 19 minutes (failing due to state explosion) to ~10 seconds (passing).
]

// Implementation & Result
#title-slide[
  Implementation & Result
]

#slide(title: "Implementation: The Optimized Code")[
  - Replaced "Heavy" runtime checks (`checked_add`) with raw arithmetic (`+` / `-`) for VMM performance where provably safe.
  - Implemented formal proofs in `packet.rs`:
    - `verify_tx_parse_header_no_panic`
    - `verify_tx_write_from_offset_to_no_panic`
    - `verify_rx_read_at_offset_from_no_panic`
]

#slide(title: "Result: Discovery of Latent Bugs")[
  *During the formal verification audit, several critical vulnerabilities were found:*
  
  - *Data Plane (`packet.rs`)*: `u32` integer overflows/underflows discovered in packet offset calculations and length checks. (e.g., `count = 0` + Massive `offset`).
  - *Buffer Overflow (`txbuf.rs`)*: Found an overflow risk in `self.len() + src.len() > Self::SIZE` which could allow Out-of-Bounds writes.
  - *DoS via Event Handler (`event_handler.rs`)*: Discovered `unwrap()` calls on VirtIO ring processing that allowed a guest to remotely crash the VMM.
]

#slide(title: "Result: Verification Success")[
  *All discovered vulnerabilities were remediated and formally proven safe:*
  
  - *Remediation*: Implemented safe math (`checked_sub`/`checked_add`) and graceful error recovery (removed `unwrap()`).
  - *Formal Proof*: Kani proves that with these fixes, the arithmetic is *mathematically impossible* to overflow, and the event loop cannot panic.
  - *Summary*: 
    - 3 Arithmetic Security Bugs Fixed (`packet.rs`)
    - 3 Critical Panic Paths Fixed (`event_handler.rs`)
    - 1 Buffer Overflow Fixed (`txbuf.rs`)
]


// Future Work
#title-slide[
  Future Work
]
