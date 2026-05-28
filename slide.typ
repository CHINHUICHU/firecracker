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
  title: "Verifying Firecracker Vsock with Kani",
  authors:
    "Group4
- B11902167 鐘文駿
- B11902071 楊子榮
- R12944041 朱晉輝
    ",
)

#slide()[
  #text(size: 30pt)[
    *Content*
  ]
  
  1. Introduction
  2. Approach
  3. Implementation & Result
    - Arithmetic-based Fixes
    - Behavior-based Fixes
  4. Future Work
]



// Introduction
#title-slide[
  Introduction
]

// Introduction: Verification
#slide(title: "Formal Verification")[
  #text(size: 22pt)[
    *What is Formal Verification?*
  ]
  
  - *Formal Verification*: 
    - Uses mathematical methods
    - Can prove software behaves correctly (against a specification) 
    - For *all possible* executions.
  - *Methods*: 
    - Model checking
    - Theorem proving
    - Abstract Interpretation
    - Symbolic execution
    - SMT-based verification
  // kani::tool-comparison.md
  // model checkers like Kani will cleverly encode program traces as symbolic "SAT/SMT" problems
]

// #slide(title: "cf. Testing")[
//   - *Testing*: Checks selected executions.
//   // QA engineers joke
// ]

// Introduction: Kani
#slide(title: "Kani Rust Verifier")[
  #text(size: 22pt)[
    *What is Kani?*
  ]
  
  Kani is a bit-precise verifier for Rust using Bounded Model Checking (BMC)
  
  #linebreak()
  #cols(columns: (1.5fr, 1.2fr), gutter: 0.1em)[
    *Capabilities*:
    #cols(columns: (1fr, 1.2fr), gutter: 0.1em)[
  - `kani::any()`
  - `kani::assume()`
  - `assert!()`
    ][
  - `#[kani::proof]`
  - `#[kani::stub()]`
  - `#[kani::unwind()]`
  ]][
    #image("kani_icon.png", width: 10cm)
  ]

  // Diff about verus
  //    SMT-based verification
  //    theorem proving
  //    unbounded (can write loop invariant)
]



#slide(title: "Kani Rust Verifier")[
  #text(size: 22pt)[
    *Kani example harness*
  ]
  ```rust
  #[kani::proof]
  fn check_my_property() {
     // Create a nondeterministic input
     let input: u8 = kani::any();
  
     // Call the function under verification
     // Automatic check if overflow or panic
     let output = function_under_test(input);
  
     // Check if it meets the specification
     assert!(meets_specification(input, output));
  }
  ```
]

// Introduction: Firecracker
#slide(title: "Firecracker")[
  #cols(columns: (3fr, 1.2fr), gutter: 1em)[
      *What is Firecracker?*
      - *Definition*: A KVM-based VMM written in Rust
      - *Purpose*: Runs *microVMs* for serverless workloads
      - *Context*: Powers AWS Fargate and AWS Lambda
    ][
      #image("Firecracker_icon.png", width: 4.5cm)
    ]
  
  #framed(title: "Key Design Principles")[
    - #stress("Security & Resource"): Isolation via `seccomp` and `cgroups`
    - #stress("Performance"): < 125ms boot time, < 5 MiB memory overhead
    // Performance test under 1CPU 128MiB RAM 
    // with constrains in SPECSIFICATION.md
  ]
]

#slide(title: "Firecracker Threat Model")[
  #cols(columns: (1.2fr, 1.1fr), gutter: 1em)[
    *Assumption*
    - Guest OS and all applications running inside the microVM are *untrusted*.


    *Security Barrier*
    - Information must only flow through explicitly configured, secure interfaces (Virtio/HTTP API).
  ][
    #framed(back-color: white, title: "Trusted vs. Untrusted")[
      - *Trusted 🟢*
        - Host OS
        - Firecracker binary
      - *Untrusted 🔴*
        - Guest Kernel
        - Guest Userspace
    ]
  ]
  // Why Rust isn't enough? 
  // While Rust guarantees memory safety
  // it does not prevent 
  //     logic bugs
  //     integer overflows/underflows
  //     unexpected panics (`unwrap()`)

  // The Vsock Data Path (`packet.rs`) handles raw bytes directly controlled by the untrusted guest
  // Any panic in the VMM thread triggers DoS, crashing the entire microVM.
]

#slide(title: "Firecracker Vsock")[
  #cols(columns: (2fr, 1fr), gutter: 1.5em)[
    === Vsock
    - Virtualization-optimized socket protocol
    - Between a guest VM and the host 
  
  ][
    #image("vsock_connection.png", width: 5cm)
  ]
  
  === Use Cases
  #set text(size: 18pt)
  - *Agent Communication*: hosting control plane agents inside the microVM
  - *Debugging and logging*: guest logs can be streamed to a host logging daemon
  - *Serverless Workloads*: workflows where traditional TCP stack setup latency is slow.

  // What is the diff of vsock and other virtio devices?
]

#slide(title: "Vsock Data Flow Architecture")[
  #align(center)[
    #set text(size: 18pt)
    #block(stroke: 1pt, inset: 1em, radius: 5pt, fill: luma(250), height: 350pt)[
      #grid(
        columns: (1.2fr, 0.4fr, 2fr, 0.4fr, 1.2fr),
        align: horizon + center,
        column-gutter: 5pt,
        row-gutter: 15pt,

        [*GUEST SPACE*], [], [*FIRECRACKER (VMM)*], [], [*HOST SPACE*],

        // Layer 1: App/Sockets
        [#rect(fill: blue.lighten(90%), radius: 4pt, inset: 8pt)[Guest App \ (AF_VSOCK)]],
        [],
        [#rect(fill: gray.lighten(90%), radius: 4pt, inset: 8pt)[`event_handler.rs` \ (Epoll loop)]],
        [],
        [#rect(fill: green.lighten(90%), radius: 4pt, inset: 8pt)[Host App \ (AF_UNIX)]],

        // Layer 2: Queues/Parser
        [#rect(fill: blue.lighten(95%), radius: 4pt, inset: 8pt)[VirtIO Queues \ (RX / TX)]],
        [$arrow.l.r$],
        [#rect(fill: orange.lighten(80%), radius: 4pt, stroke: 1.5pt + orange, inset: 8pt)[`packet.rs` \ (The Shield / Parser)]],
        [$arrow.l.r$],
        [#rect(fill: green.lighten(95%), radius: 4pt, inset: 8pt)[Unix Domain \ Sockets]],

        // Layer 3: Logic
        [], [],
        [#rect(fill: orange.lighten(90%), radius: 4pt, inset: 8pt)[`connection.rs` \ (State & Credit Control)]],
        [], [],
        // Layer 4: Muxer
        [], [],
        [#rect(fill: orange.lighten(95%), radius: 4pt, inset: 8pt)[`muxer.rs` \ (Port Routing)]],
        [], []
      )
    ]
  ]

  // 底下用講的
  
  // #v(1em)
  // #set text(size: 15pt)
  // #columns(2)[
  //   *TX Path (Guest $arrow$ Host):*
  //   1. Driver puts packet in TX Queue.
  //   2. `packet.rs` validates header/offsets.
  //   3. `connection.rs` checks credit.
  //   4. `muxer.rs` writes to host UDS.

  //   #colbreak()

  //   *RX Path (Host $arrow$ Guest):*
  //   1. `event_handler` detects UDS data.
  //   2. `muxer` routes data to Connection.
  //   3. `packet.rs` builds 44-byte header.
  //   4. Data pushed to Guest RX Queue.
  // ]

  // Epoll loop (event poll in loop)
  // event poll in a sys call in linux kernel handling IO event
  // In vsock, it handle
  //    Device activation
  //    RX queue available
  //    TX queue available
]

// Approach
#title-slide[
  Approach
]

// #slide(title: "Approach: Target Selection")[
//   - *Vsock Packet Parser*: A high-risk attack surface where the guest fully controls the 44-byte header and descriptor geometry.
//   - *Goal*: Move from "Defensive Runtime Checks" to "Proven Mathematical Safety" using formal verification.
//   - *Tool*: Kani Rust Verifier (Bounded Model Checking).
//   - *Scope*: Systematically verify the entire Vsock data path (`packet.rs`), buffering (`txbuf.rs`), and event handling (`event_handler.rs`).
// ]

// #slide(title: "Approach: Refactoring for Verifiability")[
//   - *The Challenge*: `VsockPacketTx::parse` mixes FFI/mmap logic (intractable for Kani) with validation (verifiable).
//   - *The Solution*: Refactored `parse` into two distinct steps:
//     1. #underline[FFI Step]: `load_descriptor_chain` (Memory I/O).
//     2. #underline[Pure Step]: `parse_header` (Validation Logic).
//   - *Benefit*: Allows proof harnesses to target the validation arithmetic in isolation.
// ]

// #slide(title: "Approach: Contract-Based Stubbing")[
//   - *Stubbing*: Replaced complex scatter-gather I/O (`read_exact_volatile_at`) with a simplified mathematical contract.
//   - *Focus*: Proving the *arithmetic* of the header validation, not the memory-safety of the entire `vm-memory` crate.
//   - *Performance*: Verification time dropped from 19 minutes (failing due to state explosion) to ~10 seconds (passing).
// ]

#slide(title: "Approach: Verification Methodology")[
  #let step(n, title, body) = grid(
    columns: (2em, 1fr),
    gutter: 0.5em,
    align(center + top, text(size: 18pt, weight: "bold", fill: blue.darken(20%))[#n]),
    [*#title* \ #body],
  )

  #step("①", "Target Selection — Follow the Trust Boundary")[
    Identify where guest-controlled data enters the system. Prioritize arithmetic on untrusted fields (silent overflow) and logic that can be driven into edge states by adversarial input.
  ]

  // #v(0.5em)

  #step("②", "Failure Analysis and Fix")[
    A failing harness yields a concrete counter-example. Understand its semantics first, then apply the *minimal* fix that closes the property. Write a passing harness to prove the fix holds for all inputs.
  ]

  // #v(0.5em)

  #step("③", "Reachability Analysis")[
    A counter-example proves the *code* has a flaw — not necessarily that the *system* is exploitable. Trace all call sites to determine whether a guest can reach it today, or whether the risk is latent (the function is `pub` and future callers could trigger it).
  ]
]

// Implementation & Result
#title-slide[
  Implementation & Result
]


#slide(title: "Bugs Found: Two Categories")[
  #cols(columns: (1fr, 1fr), gutter: 2em)[
    #framed(title: "Arithmetic-based")[
      A single crafted header field value is enough to trigger the bug.

      #v(0.3em)
      - `write_from_offset_to` #linebreak()
        #text(size: 13pt, fill: gray)[`offset + 44` → u32 overflow (TX path)]
      - `read_at_offset_from` #linebreak()
        #text(size: 13pt, fill: gray)[same expression, RX path]
      - `peer_avail_credit()` #linebreak()
        #text(size: 13pt, fill: gray)[Wrapping sub → credit wraps to ~4 GB]
    ]
  ][
    #framed(title: "Behavior-based")[
      Requires sustained flooding to drive the queue into a specific state.

      #v(0.3em)
      - `MuxerRxQ::push(RstPkt)` #linebreak()
        #text(size: 13pt, fill: gray)[desynced + all-RST + non-full → RST silently dropped]
    ]
  ]
]

#slide(title: "Function Interaction Map")[
  #let node(body) = rect(
    fill: luma(235),
    stroke: 0.6pt + luma(160),
    inset: (x: 8pt, y: 5pt),
    radius: 3pt,
    width: 100%,
    text(size: 12pt, body)
  )
  #let bug_node(body) = rect(
    fill: red.lighten(80%),
    stroke: 1pt + red.lighten(30%),
    inset: (x: 8pt, y: 5pt),
    radius: 3pt,
    width: 100%,
    text(size: 12pt, body)
  )
  #let arr = align(center, text(size: 14pt, sym.arrow.b))

  #cols(columns: (1fr, 1fr), gutter: 1.5em)[
    #align(center)[*TX path — Guest #sym.arrow.r Host*]
    #v(0.3em)
    #stack(spacing: 0.2em,
      node[*Guest* app writes packet \ #text(size: 11pt, fill: gray)[`hdr.len`, `buf_alloc`, `fwd_cnt` guest-controlled]],
      arr,
      node[`packet.rs` — `VsockPacketTx::parse()`],
      arr,
      bug_node[*`write_from_offset_to`* \ #text(size: 11pt)[`offset + 44` overflows when `count = 0`]],
      arr,
      node[`connection.rs` #sym.arrow `unix/muxer.rs`],
      arr,
      bug_node[*`MuxerRxQ::push(RstPkt)`* \ #text(size: 11pt)[RST silently dropped \ #text(fill: gray)[error path: guest sends to unknown port]]],
    )
  ][
    #align(center)[*RX path — Host #sym.arrow.r Guest*]
    #v(0.3em)
    #stack(spacing: 0.2em,
      node[*Host* `AF_UNIX` socket has data],
      arr,
      node[`unix/muxer.rs` — finds connection with pending data],
      arr,
      bug_node[*`peer_avail_credit()`* \ #text(size: 11pt)[guest sets `buf_alloc = 0` → credit wraps to ~4 GB]],
      arr,
      bug_node[*`read_at_offset_from`* \ #text(size: 11pt)[`offset + 44` overflows when `count = 0`]],
      arr,
      node[Virtio RX queue → *Guest* app receives data],
    )
  ]

  #v(0.3em)
  #align(center, text(size: 11pt, fill: gray)[#rect(fill: red.lighten(80%), stroke: 1pt + red.lighten(30%), inset: 3pt, radius: 2pt)[shaded] = verified bug location])
]

#title-slide[
  Arithmetic-based Fixes
]


#title-slide[
  `write_from_offset_to
  & read_at_offset_from`
]

#slide(title: "Verification Property")[
  #framed(title: [Target: `VsockPacketTx::write_from_offset_to`])[
    Guest controls `offset` and `count` (via the vsock header). We want to prove the function is *panic-free* for *all possible inputs*.
  ]

  // *Key concern*: the expression `offset + VSOCK_PKT_HDR_SIZE` (= offset + 44) is a bare `u32` addition. If `offset` is near `u32::MAX`, this silently wraps and produces a wrong memory address.

  // #framed(title: "Property to prove")[
  //   No integer overflow on any execution path, for any `(buf_len, offset, count) ∈ u32³`.
  // ]
]

#slide(title: "The Target Function: write_from_offset_to")[
  #text(size: 20pt)[
    ```rust
    // offset: byte offset into the payload
    // count: bytes to copy
    pub fn write_from_offset_to<T: WriteVolatile>(
        &self, dst: &mut T, offset: u32, count: u32,
    ) -> Result<u32, VsockError> {
        if count > self.buffer.len()
            .saturating_sub(VSOCK_PKT_HDR_SIZE)
            .saturating_sub(offset)
        {
            return Err(VsockError::GuestMemoryBounds);
        }
        // read_volatile_at: bounds-aware memcpy out of guest memory
        self.buffer.read_volatile_at(
            dst, (offset + VSOCK_PKT_HDR_SIZE) as usize, count as usize
        )
    }
    ```
  ]
  // #grayed[When `count = 0`, the bounds check becomes `0 > X`, which is *always false* — every `offset` passes through unchecked.]
]

#slide(title: "The Harness")[
  ```rust
  #[kani::proof]
  #[kani::unwind(2)]
  #[kani::solver(cadical)]
  fn verify_tx_write_from_offset_to_no_panic() {
      let buf_len: u32 = kani::any();  // symbolic: all possible lengths
      let offset: u32  = kani::any();  // symbolic: all possible offsets
      let count: u32   = kani::any();  // symbolic: all possible counts

      let pkt = VsockPacketTx {
          hdr: VsockPacketHeader::default(),
          buffer: IoVecBuffer::with_len(buf_len),
      };
      // stub dst: discards all bytes written, no real I/O
      let mut sink = KaniSink; 
      let _ = pkt.write_from_offset_to(&mut sink, offset, count);
  }
  ```
]


#slide(title: "Kani Output: Verification Failed")[
  Running the harness against the function:

  ```
  cargo kani --package vmm --harness verify_tx_write_from_offset_to_no_panic
  ```

  #v(0.4em)

  ```
  SUMMARY:
   ** 1 of 559 failed (11 unreachable)
  Failed Checks: attempt to add with overflow
   File: "src/vmm/src/devices/virtio/vsock/packet.rs", line 277, in
   ...::VsockPacketTx::write_from_offset_to::<...::KaniSink>

  VERIFICATION:- FAILED
  Verification Time: 5.2412553s
  ```
]

#slide(title: "Debugging with --concrete-playback")[
  Kani can generate a concrete unit test that *replays the exact failing input*:

  ```
  cargo kani --package vmm \
    --harness verify_tx_write_from_offset_to_no_panic \
    -Z concrete-playback --concrete-playback=print
  ```

  #v(0.3em)

  ```rust
  #[test]
  fn kani_concrete_playback_verify_tx_write_from_offset_to_no_panic_3086...() {
      let concrete_vals: Vec<Vec<u8>> = vec![
          vec![16, 255, 255, 191],   // buf_len = 3_221_225_232
          vec![213, 255, 255, 255],  // offset  = 4_294_967_253 (u32::MAX − 42)
          vec![0, 0, 0, 0],          // count   = 0
      ];
      kani::concrete_playback_run(concrete_vals, verify_tx_write_from_offset_to_no_panic);
  }
  ```

  // #framed[
  //   `offset + 44` = `4_294_967_253 + 44` = `4_294_967_297` → wraps to `1` (u32 overflow). \ Run with `cargo test` to reproduce the panic locally.
  // ]
]

#slide(title: "Counter-Example Found")[
  #cols(columns: (1fr, 1fr), gutter: 2em)[
    *Kani reports failure:*
    #framed[
      - `count  = 0`
      - `offset = 4294967252` \
        (`= u32::MAX − 43`)
      - `buf_len` = any value
    ]
  ][
    *Why it fails:*
    1. Bounds check: `0 > buf_len − 44 − offset` \
       → always false → *passes*
    2. Addition: `4294967252 + 44` \
       → wraps to `4` (u32 overflow!)
  ]
]

#slide(title: "The Fix")[
  Add an early-return guard for the zero-count case:

  #cols(columns: (1fr, 1fr), gutter: 1.5em)[
    *Before (vulnerable)*:
    #text(size: 16pt)[
      ```rust
      // no guard
      if count > self.buffer.len()
          .saturating_sub(HDR_SIZE)
          .saturating_sub(offset)
      {
          return Err(...);
      }
      // offset + 44 may overflow!
      ```
    ]
  ][
    *After (fixed)*:
    #text(size: 16pt)[
      ```rust
      if count == 0 {
          return Ok(0); // load-bearing
      }
      if count > self.buffer.len()
          .saturating_sub(HDR_SIZE)
          .saturating_sub(offset)
      {
          return Err(...);
      }
      // count > 0 ⟹ offset ≤ buf_len−45
      // ∴ offset + 44 ≤ u32::MAX  ✓
      ```
    ]
  ]
]

// #slide(title: "Call Chain: How write_from_offset_to Is Reached 1")[
//   #let node(body, accent: false) = rect(
//     fill: if accent { blue.lighten(65%) } else { luma(235) },
//     stroke: 0.6pt + luma(160),
//     inset: (x: 8pt, y: 5pt),
//     radius: 3pt,
//     width: 100%,
//     text(size: 14pt, body)
//   )
//   #let arr = align(center, text(size: 16pt, sym.arrow.b))

//   #stack(spacing: 0.25em,
//     node[*Guest App* writes packet to virtio TX ring \ #text(size: 12pt, fill: gray)[`hdr.len` set by guest — fully attacker-controlled]],
//     arr,
//     node[`event_handler.rs` — `handle_txq_event()` receives TX queue kick],
//     arr,
//     node[`device.rs` — `process_tx()`: calls `tx_packet.parse()`, then `backend.send_pkt(&tx_packet)`],
//     arr,
//     node[`unix/muxer.rs` — `VsockMuxer::send_pkt()`: routes packet to the matching connection],
//     arr,
//     node[`csm/connection.rs` — `VsockConnection::send_pkt()`: dispatches `OP_RW` to `send_bytes(pkt)`],
//     arr,
//     node(accent: true)[`packet.rs` — `write_from_offset_to(dst, offset=0, count=`*`pkt.hdr.len()`*`)` #h(1fr) #text(fill: red.darken(20%))[← target: `count` is guest-controlled]],
//   )
// ]

#slide(title: "Call Chain: How write_from_offset_to Is Reached")[
  Where is `write_from_offset_to` called? — `csm/connection.rs: send_bytes()`

  #text(size: 17pt)[
    ```rust
    fn send_bytes(&mut self, pkt: &VsockPacketTx) -> Result<(), VsockError> {
        let len = pkt.hdr.len();  // ← guest-controlled u32

        // Case 1: TX buffer non-empty → spill all
        pkt.write_from_offset_to(&mut self.tx_buf, 0, len);

        // Case 2: direct stream write
        let written = pkt.write_from_offset_to(&mut self.stream, 0, len);

        // Case 3: partial write — spill remainder
        if written < len {
            pkt.write_from_offset_to(&mut self.tx_buf, written, len - written)?;
        }
    }
    ```
  ]
  // #grayed[`len` comes from the guest header — a malicious guest can set it to `0`.]
]

#slide(title: "Could the Counter-Example Be Triggered?")[
  #table(
    columns: (2fr, 1fr, 1.5fr, 2fr),
    table.header([*Call site*], [*offset*], [*count*], [*Overflow?*]),
    [Case 1/2: `len = 0`], [`0`], [`0`], [`0 + 44 = 44` — safe ✓],
    [Case 3: partial write], [`written ≤ len`], [`len − written > 0`], [count > 0, guard fires ✓],
  )

  // #v(0.4em)

      ```rust
      pub fn write_from_offset_to<T: WriteVolatile>(
          &self, dst: &mut T, offset: u32, count: u32,
      ) -> Result<u32, VsockError> {
          (... omitted)
          // VSOCK_PKT_HDR_SIZE = 44
          self.buffer.read_volatile_at(
              dst, (offset + VSOCK_PKT_HDR_SIZE) as usize, count as usize
          )
      }
    ```

  Under current call sites, `offset` is always `0` when `count = 0`. \
  The exact counter-example (`count = 0`, `offset ≈ u32::MAX`) is *not reachable in practice*.
  
]

// // Fix: read_at_offset_from (packet.rs)
// #slide(title: "Verification Property: read_at_offset_from")[
//   #framed(title: [Target: `VsockPacketRx::read_at_offset_from`])[
//     The RX counterpart of `write_from_offset_to`. Reads data from the host Unix stream and writes it into the guest's RX virtio buffer. We want to prove it is *panic-free* for *all possible inputs*.
//   ]

//   *Key concern*: the same bare `u32` addition — `offset + VSOCK_PKT_HDR_SIZE` (= offset + 44) — appears on the RX path. The same overflow is possible when `count = 0`.

//   *Direction*: host → guest (opposite of `write_from_offset_to`).
// ]

// #title-slide[
//   `read_at_offset_from`
// ]

#slide(title: "Similar Issue: read_at_offset_from")[
  #text(size: 20pt)[
    ```rust
    pub fn read_at_offset_from<T: ReadVolatile>(
        &mut self, src: &mut T, offset: u32, count: u32,
    ) -> Result<u32, VsockError> {
        if count > self.buffer.len()
            .saturating_sub(VSOCK_PKT_HDR_SIZE)
            .saturating_sub(offset)
        {
            return Err(VsockError::GuestMemoryBounds);
        }
        self.buffer.write_volatile_at(
            src, (offset + VSOCK_PKT_HDR_SIZE) as usize, count as usize
        )
    }
    ```
  ]
]

// #slide(title: "The Harness")[
//   ```rust
//   #[kani::proof]
//   #[kani::unwind(2)]
//   #[kani::solver(cadical)]
//   fn verify_rx_read_at_offset_from_no_panic() {
//       let buf_len: u32 = kani::any();
//       let offset: u32  = kani::any();
//       let count: u32   = kani::any();

//       let mut pkt = VsockPacketRx {
//           hdr: VsockPacketHeader::default(),
//           buffer: IoVecBufferMut::with_len(buf_len),
//       };
//       let mut sink = KaniSink;
//       let _ = pkt.read_at_offset_from(&mut sink, offset, count);
//       std::mem::forget(pkt); // buffer has no real mmap; skip munmap on drop
//   }
//   ```
// ]

// #slide(title: "Counter-Example Found")[
//   #cols(columns: (1fr, 1fr), gutter: 2em)[
//     *Kani reports failure:*
//     #framed[
//       - `count  = 0`
//       - `offset = 4294967252` \
//         (`= u32::MAX − 43`)
//       - `buf_len` = any value
//     ]
//   ][
//     *Why it fails:*
//     1. Bounds check: `0 > buf_len − 44 − offset` \
//        → always false → *passes*
//     2. Addition: `4294967252 + 44` \
//        → wraps to `4` (u32 overflow!)
//   ]

//   #grayed[Structurally identical to the `write_from_offset_to` counter-example — same arithmetic expression, opposite data direction.]
// ]

// #slide(title: "The Fix")[
//   The same `count == 0` early-return guard:

//   #cols(columns: (1fr, 1fr), gutter: 1.5em)[
//     *Before (vulnerable)*:
//     #text(size: 16pt)[
//       ```rust
//       // no guard
//       if count > self.buffer.len()
//           .saturating_sub(HDR_SIZE)
//           .saturating_sub(offset)
//       {
//           return Err(...);
//       }
//       // offset + 44 may overflow!
//       ```
//     ]
//   ][
//     *After (fixed)*:
//     #text(size: 16pt)[
//       ```rust
//       if count == 0 {
//           return Ok(0); // load-bearing
//       }
//       if count > self.buffer.len()
//           .saturating_sub(HDR_SIZE)
//           .saturating_sub(offset)
//       {
//           return Err(...);
//       }
//       // count > 0 ⟹ offset ≤ buf_len−45
//       // ∴ offset + 44 ≤ u32::MAX  ✓
//       ```
//     ]
//   ]
// ]

// #slide(title: "Call Chain: How read_at_offset_from Is Reached")[
//   #let node(body, accent: false) = rect(
//     fill: if accent { blue.lighten(65%) } else { luma(235) },
//     stroke: 0.6pt + luma(160),
//     inset: (x: 8pt, y: 5pt),
//     radius: 3pt,
//     width: 100%,
//     text(size: 14pt, body)
//   )
//   #let arr = align(center, text(size: 16pt, sym.arrow.b))

//   #stack(spacing: 0.25em,
//     node[*Host Unix socket* has data ready — epoll event fires in the VMM],
//     arr,
//     node[`event_handler.rs` — `handle_backend_event()`: wakes the VMM thread],
//     arr,
//     node[`unix/muxer.rs` — `VsockMuxer::recv_pkt()`: finds connection with `PendingRx::Rw`],
//     arr,
//     node[`csm/connection.rs` — `VsockConnection::recv_pkt()`: \ `let max_len = min(pkt.buf_size(),` *`self.peer_avail_credit()`*`)` ],
//     arr,
//     node(accent: true)[`packet.rs` — `read_at_offset_from(&mut self.stream, 0, max_len)` #h(1fr) #text(fill: red.darken(20%))[← target: writes host data into guest RX buffer]],
//   )
// ]

// #slide(title: "Could the Counter-Example Be Triggered?")[
//   *No — not reachable at the current call site.*

//   #table(
//     columns: (2fr, 1fr, 1.5fr, 2fr),
//     table.header([*Call site*], [*offset*], [*count*], [*Overflow?*]),
//     [`recv_pkt()`: `count = max_len`], [`0`], [`≤ peer_avail_credit()`], [`0 + 44 = 44` — safe ✓],
//   )

//   #v(0.4em)

//   The only call site always passes `offset = 0` — the addition `0 + 44` is always safe. \
//   The exact counter-example (`count = 0`, `offset ≈ u32::MAX`) is *not reachable in practice*.

//   // #framed(title: "Why the fix is still necessary")[
//   //   `read_at_offset_from` is `pub` — future callers could pass a non-zero `offset` with `count = 0`. The guard makes the function safe *by contract*, not just by caller discipline.
//   // ]
// ]

#title-slide[
  `peer_avail_credit`
]
#slide(title: "Verification Property: peer_avail_credit")[
  #framed(title: [Target: `VsockConnection::peer_avail_credit()`])[
    Determines how many bytes we may send to the peer. If it returns a value *larger than `peer_buf_alloc`*, we over-send — writing beyond the peer's buffer.
  ]

  Fields involved:
  - `peer_buf_alloc` — peer's total RX buffer size, *set from guest header* (`pkt.hdr.buf_alloc()`)
  - `rx_cnt` — total bytes sent to peer (local counter)
  - `peer_fwd_cnt` — bytes peer has drained, *set from guest header* (`pkt.hdr.fwd_cnt()`)

  #framed(title: "Property to prove")[
    `peer_avail_credit() ≤ peer_buf_alloc` for all possible inputs.
  ]
]

#slide(title: "The Original Function")[
  #text(size: 20pt)[
    ```rust
    fn peer_avail_credit(&self) -> u32 {
        (Wrapping(self.peer_buf_alloc)
            - (self.rx_cnt - self.peer_fwd_cnt)).0
    }
    ```
  ]

  `Wrapping` arithmetic *never panics* — but it silently wraps on underflow.

  If the guest sends `buf_alloc = 0` while bytes are in flight:
  - `in_flight = rx_cnt − peer_fwd_cnt > 0`
  - `Wrapping(0) − Wrapping(in_flight)` wraps to `u32::MAX − in_flight + 1`
  - Result: we think the peer has *~4 GB of free buffer* → we over-send
]

#slide(title: "The Harness")[
  ```rust
  #[kani::proof]
  fn verify_peer_avail_credit_wrapping_can_exceed_alloc() {
      let peer_buf_alloc: u32  = kani::any();
      let rx_cnt               = Wrapping::<u32>(kani::any());
      let peer_fwd_cnt         = Wrapping::<u32>(kani::any());

      // Original (buggy) implementation.
      let credit = (Wrapping(peer_buf_alloc) - (rx_cnt - peer_fwd_cnt)).0;

      // FAILS: when in_flight > peer_buf_alloc, credit wraps to a value near u32::MAX.
      assert!(credit <= peer_buf_alloc);
  }
  ```
]

// #slide(title: "Kani Output: Verification Failed")[
//   Running the harness against the *original* `Wrapping` implementation:

//   ```
//   SUMMARY:
//    ** 1 of 1 failed
//   Failed Checks: assertion failed: credit <= peer_buf_alloc
//    File: "src/vmm/src/devices/virtio/vsock/csm/connection.rs", line 703, in
//    ...::verify_peer_avail_credit_wrapping_can_exceed_alloc

//   VERIFICATION:- FAILED
//   Verification Time: 0.029860348s
//   ```
// ]

// #slide(title: "Debugging with --concrete-playback")[
//   ```
//   cargo kani --package vmm \
//     --harness verify_peer_avail_credit_wrapping_can_exceed_alloc \
//     --concrete-playback=print
//   ```

//   #v(0.3em)

//   ```rust
//   #[test]
//   fn kani_concrete_playback_verify_peer_avail_credit_wrapping_..._14478...() {
//       let concrete_vals: Vec<Vec<u8>> = vec![
//           vec![254, 255, 255, 255],  // peer_buf_alloc = 4_294_967_294  (u32::MAX − 1)
//           vec![254, 255, 255, 255],  // rx_cnt         = 4_294_967_294  (u32::MAX − 1)
//           vec![255, 255, 255, 255],  // peer_fwd_cnt   = 4_294_967_295  (u32::MAX)
//       ];
//       kani::concrete_playback_run(concrete_vals, verify_peer_avail_credit_wrapping_can_exceed_alloc);
//   }
//   ```

//   #grayed[`peer_fwd_cnt > rx_cnt` — the guest claims to have drained *more bytes than were ever sent*. Impossible under honest operation; freely crafted by a malicious guest.]
// ]

#slide(title: "Counter-Example Found")[
  #cols(columns: (1fr, 1fr), gutter: 2em)[
    // *Concrete values (from playback):*
    #framed[
      - `peer_buf_alloc = u32::MAX − 1`
      - `rx_cnt = u32::MAX − 1`
      - `peer_fwd_cnt = u32::MAX`
    ]

  ][
    // *Execution trace:*
    // 1. `rx_cnt − peer_fwd_cnt` = `Wrapping(−1)` = `u32::MAX` \
    //    #text(size: 13pt, fill: gray)[guest claims to have drained more than was sent]
    // 2. `Wrapping(u32::MAX−1) − Wrapping(u32::MAX)` = `u32::MAX`
    // 3. `u32::MAX > u32::MAX−1` → assertion *fails*
    *Impact:*
    - `recv_pkt()` uses credit as `max_len`
    - `max_len = min(pkt.buf_size(), u32::MAX)`
    - We read up to the full RX descriptor into the guest
    - Peer's actual buffer may be *full or empty*
    - Result: peer's buffer overflows with data it cannot hold
  ]
]

#slide(title: "The Fix")[
  Replace `Wrapping` subtraction with `saturating_sub`:

  #cols(columns: (1fr, 1fr), gutter: 1.5em)[
    *Before (vulnerable)*:
    #text(size: 17pt)[
      ```rust
      fn peer_avail_credit(&self) -> u32 {
          (Wrapping(self.peer_buf_alloc)
              - (self.rx_cnt
                 - self.peer_fwd_cnt)).0
          // wraps silently on underflow
      }
      ```
    ]
  ][
    *After (fixed)*:
    #text(size: 17pt)[
      ```rust
      fn peer_avail_credit(&self) -> u32 {
          let in_flight =
              (self.rx_cnt - self.peer_fwd_cnt).0;
          self.peer_buf_alloc
              .saturating_sub(in_flight)
          // clamps to 0 — stop sending
      }
      ```
    ]
  ]

  `saturating_sub` returns `0` when `in_flight > peer_buf_alloc` — the connection *stops sending* rather than over-running the peer's buffer.
]

#slide(title: "Call Chain: How peer_avail_credit Is Reached")[
  #let node(body, accent: false) = rect(
    fill: if accent { blue.lighten(65%) } else { luma(235) },
    stroke: 0.6pt + luma(160),
    inset: (x: 8pt, y: 5pt),
    radius: 3pt,
    width: 100%,
    text(size: 14pt, body)
  )
  #let arr = align(center, text(size: 16pt, sym.arrow.b))

  #stack(spacing: 0.25em,
    node[*Guest* sends TX packet — `hdr.buf_alloc` and `hdr.fwd_cnt` are *fully guest-controlled*],
    arr,
    node[`csm/connection.rs` — `send_pkt()`: \ `self.peer_buf_alloc = pkt.hdr.buf_alloc()` \ `self.peer_fwd_cnt = Wrapping(pkt.hdr.fwd_cnt())`],
    arr,
    node[`csm/connection.rs` — `recv_pkt()` (host→guest data path): \ `let max_len = min(pkt.buf_size(),` *`self.peer_avail_credit()`*`)`],
    arr,
    node(accent: true)[`connection.rs` — `peer_avail_credit()` #h(1fr) #text(fill: red.darken(20%))[← both inputs guest-controlled]],
  )
]

#slide(title: "Could the Counter-Example Be Triggered?")[
  *Yes — may be reachable by a malicious guest.*

  #table(
    columns: (2fr, 3fr),
    table.header([*Step*], [*Guest action*]),
    [Set `buf_alloc = 0`], [Guest sends any packet with `hdr.buf_alloc = 0`],
    [Keep bytes in flight], [Guest has previously sent data that VMM forwarded (`rx_cnt > 0`)],
    [Do not advance `fwd_cnt`], [Guest sends stale/low `hdr.fwd_cnt`, making `in_flight > 0`],
  )

  #v(0.4em)

  // All three fields come directly from the guest packet header — no other precondition needed.

  // #framed(title: "Why the fix closes the attack")[
  //   `saturating_sub` clamps the credit to `0` when `in_flight > peer_buf_alloc`. The connection simply stalls (stops sending) instead of over-running the peer buffer.
  // ]
]

#title-slide[
  Behavior-based Fix
]

#title-slide[
  `MuxerRxQ::push()`
]

// Fix 1: muxer_rxq.rs RST drop
#slide(title: "Verification Property: RST Push")[
  #framed(title: [Target: `MuxerRxQ::push()` in `unix/muxer_rxq.rs`])[
    The RX queue delivers packets from host to guest. RST packets *must not be silently dropped* when the queue has room — a dropped RST leaves the peer's connection open indefinitely.
  ]

  Queue states:
  - *Synced + non-full*: normal operation, push always succeeds
  - *Desync'd or full*: RST should evict a `ConnRx` entry to make room
  - *Desync'd, non-full, all-RST*: no `ConnRx` to evict — *was silently dropped*

  #framed(title: "Property to prove")[
    `push(RstPkt)` returns `true` whenever the queue has at least one free slot.
  ]

  #grayed[
    RST is the signal telling the guest a connection is rejected or dead. A silently dropped RST leaves the guest's connection open indefinitely, leaking a connection slot.
  ]
]

#slide(title: "The Original push() for RST")[
  #text(size: 17pt)[
    ```rust
    MuxerRx::RstPkt { .. } => {
        // Try to evict a ConnRx entry to make room.
        for qi in self.q.iter_mut().rev() {
            if let MuxerRx::ConnRx(_) = qi {
                *qi = rx;
                self.synced = false;
                return true;
            }
        }
        // No ConnRx found → fall through → return false
        //                ↑ BUG: queue may still have free slots!
    }
    ```
  ]

  A desync'd queue full of RST entries has *no `ConnRx` to evict*, so push falls through to `return false` — even if the queue has room.
]

#slide(title: "The Harness")[
  ```rust
  // Claim (FAILS): an RST push always succeeds regardless of queue state.
  // `KANI_FILL = 2` keeps the state space small.
  #[kani::proof]
  #[kani::unwind(5)]
  fn verify_rxq_rst_push_never_fails() {
      let n: usize = kani::any_where(|&n| n > 0 && n <= KANI_FILL);
      // A desync'd queue with only RST entries — no ConnRx to evict.
      let mut rxq = rst_queue(n, false);

      // FAILS: push() returns false when no ConnRx entry can be replaced.
      assert!(rxq.push(any_rst()));
  }
  ```
]

#slide(title: "Counter-Example Found")[
  #cols(columns: (1fr, 1fr), gutter: 2em)[
    *Counter-example:*
    #framed[
      - `n = 2` (queue full, `SIZE = 2`)
      - `synced = false`
      - All entries are `RstPkt`
    ]

    // *Execution trace:*
    // 1. `is_synced() && !is_full()` → false
    // 2. Eviction loop: no `ConnRx` found
    // 3. Falls through → returns `false`
    // 4. Assertion `assert!(push(...))` *fails*

    RST packet is *silently dropped*.
  ][
    *Impact:*
    - Peer never receives RST
    - Guest connection stays *open* on peer side
    - Peer waits for data that never arrives
    - Repeated drops exhaust guest connection pool silently
    - Caller `enq_rst()` only logs a warning — *no crash*

    // #grayed[Production `SIZE = 256`; the scenario requires filling the queue with 256 RSTs.]
  ]
]

#slide(title: "The Fix")[
  After failing to evict a `ConnRx`, push directly if the queue still has room:

  #cols(columns: (1fr, 1fr), gutter: 1.5em)[
    *Before (drops RST)*:
    #text(size: 16pt)[
      ```rust
      for qi in self.q.iter_mut().rev() {
          if let MuxerRx::ConnRx(_) = qi {
              *qi = rx;
              self.synced = false;
              return true;
          }
      }
      // no room found → false
      ```
    ]
  ][
    *After (fixed)*:
    #text(size: 16pt)[
      ```rust
      for qi in self.q.iter_mut().rev() {
          if let MuxerRx::ConnRx(_) = qi {
              *qi = rx;
              self.synced = false;
              return true;
          }
      }
      // New: push if slot available
      if !self.is_full() {
          self.q.push_back(rx);
          return true;
      }
      ```
    ]
  ]
]

#slide(title: "Call Chain: How push() Is Reached")[
  #let node(body, accent: false) = rect(
    fill: if accent { blue.lighten(65%) } else { luma(235) },
    stroke: 0.6pt + luma(160),
    inset: (x: 8pt, y: 5pt),
    radius: 3pt,
    width: 100%,
    text(size: 14pt, body)
  )
  #let arr = align(center, text(size: 16pt, sym.arrow.b))

  #stack(spacing: 0.25em,
    node[*Guest* sends a packet with no matching connection, wrong CID, or refused port],
    arr,
    node[`unix/muxer.rs` — `VsockMuxer::send_pkt()`: determines RST needed \ (unknown port / connection refused / protocol error)],
    arr,
    node[`unix/muxer.rs` — `enq_rst(dst_port, src_port)`: \ `let pushed = self.rxq.push(MuxerRx::RstPkt { ... })`],
    arr,
    node(accent: true)[`unix/muxer_rxq.rs` — `MuxerRxQ::push()` #h(1fr) #text(fill: red.darken(20%))[← target: RST may be dropped]],
  )
]

#slide(title: "Could the Counter-Example Be Triggered?")[
  *Partially — reachable but consequence is limited.*

  #table(
    columns: (2fr, 3fr),
    table.header([*Condition*], [*How guest triggers it*]),
    [Queue desync'd], [Flood connection requests to fill RX queue beyond `SIZE`],
    [All entries are RSTs], [Repeat RST-triggering packets (unknown port, refused conn)],
    [Queue not full], [Partial fill: *fixed* — RST now pushed directly],
    [Queue full (256 RSTs)], [Still drops — intentional remaining limitation],
  )

  #v(0.3em)

  // #framed(title: "Fix scope")[
  //   The fix closes the *non-full desync'd* case. The full-queue case is accepted: filling 256 slots with RSTs is a DoS prerequisite, and `enq_rst()` already handles the drop gracefully with a logged warning.
  // ]
]

// Future Work
#title-slide[
  Future Work
]

#slide(title: "Future Work: Testing")[
  - *Objective*: 
    - Increase the verification coverage in *Vsock*.
    - Test security improvements by comparing *Pre-fix* vs. *Post-fix* implementations.
  - *Method*: Subject the VMM to malicious guest-controlled packets designed to trigger the identified overflow/underflow points.
]

// // A simple slide
// #slide[
//   - This is a simple `slide` with no title.
//   - #stress("Bold and coloured") text by using `#stress(text)`.
//   - Sample link: #link("typst.app").
//     - Link styling using `link-style`: `"color"`, `"underline"`, `"both"`
//   - Font selection using `font: "Fira Sans"`, `size: 21pt`.

//   #framed[This text has been written using `#framed(text)`. The background color of the box is customisable.]

//   #framed(title: "Frame with title")[This text has been written using `#framed(title:"Frame with title")[text]`.]
// ]

// // Focus slide
// #focus-slide[
//   This is an auto-resized _focus slide_.
// ]

// // Blank slide
// #blank-slide[
//   - This is a `#blank-slide`.

//   - Available #stress[themes]#footnote[Use them as *color* functions! e.g., `#reddy("your text")`]:

//   #framed(back-color: white)[
//     #bluey("bluey"), #reddy("reddy"), #greeny("greeny"), #yelly("yelly"), #purply("purply"), #dusky("dusky"), darky.
//   ]

//   ```typst
//   #show: typslides.with(
//     ratio: "16-9",
//     theme: "bluey",
//     ...
//   )
//   ```

//   - Or just use *your own theme color*:
//     - `theme: rgb("30500B")`
// ]

// // Slide with title
// #slide(title: "Outlined slide", outlined: true)[
//   - Check out the *progress bar* at the bottom of the slide.

//     #h(1cm) `show-progress: true`

//   - Outline slides with `outlined: true`.

//   #grayed([This is a `#grayed` text. Useful for equations.])
//   #grayed($ P_t = alpha - 1 / (sqrt(x) + f(y)) $)


// ]

// // Columns
// #slide(title: "Columns")[

//   #cols(columns: (2fr, 1fr, 2fr), gutter: 2em)[
//     #grayed[Columns can be included using `#cols[...][...]`]
//   ][
//     #grayed[And this is]
//   ][
//     #grayed[an example.]
//   ]

//   - Custom spacing: `#cols(columns: (2fr, 1fr, 2fr), gutter: 2em)[...]`

//   - Sample references: @typst, @typslides.
//     - Add a #stress[bibliography slide]...

//     1. `#let bib = bibliography("you_bibliography_file.bib")`
//     2. `#bibliography-slide(bib)`
// ]


