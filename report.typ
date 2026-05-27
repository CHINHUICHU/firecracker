#set text(font: "Linux Libertine", size: 11pt)
#set heading(numbering: "1.")
#set page(paper: "a4", margin: (x: 2cm, y: 2.5cm))
#show heading.where(level: 1): set heading(numbering: none)
#show heading.where(level: 2): set heading(numbering: none)
#show heading.where(level: 3): set heading(numbering: none)
#align(center)[
  #block(inset: 2em)[
    #text(weight: "bold", size: 1.8em)[VM Final Project] \
    #text(style: "italic", size: 1.2em)[Formal Verification Audit of Firecracker Vsock]
  ]
]
#line(length: 100%, stroke: 0.5pt)

= 1. `packet.rs` (Data Plane Safety)
*Rationale*: This file is the primary entry point for raw binary data from the Guest. Any flaw here can lead to memory corruption or host information leaks.

== Component Analysis

=== 1.1 `VsockPacketTx::parse` (Line 213)
- *What it does*: This function deserializes raw bytes from a VirtIO descriptor chain into a structured `VsockPacketTx` object.
- *The Problem (Line 235)*: It used raw subtraction to check if the advertised packet length fits in the buffer: `if hdr.len > self.buffer.len() - VSOCK_PKT_HDR_SIZE`.
- *Vulnerability*: If the guest provides a buffer smaller than 44 bytes, the subtraction *underflows*, allowing the length check to be bypassed.
- *Remediation*: Replaced with `checked_sub` and explicit error handling.

=== 1.2 `VsockPacketTx::write_from_offset_to` (Line 252)
- *What it does*: Extracts data from a Guest packet at a specific `offset` and writes it to a Host destination (e.g., a socket).
- *The Problem (Line 262)*: It calculated the memory address as `(offset + VSOCK_PKT_HDR_SIZE) as usize`.
- *Vulnerability*: If a guest provides an `offset` near `u32::MAX`, the addition *overflows (wraps around)*. This tricks the host into reading from the packet header area instead of the payload, causing an *Information Leak*.
- *Remediation*: Promoted `offset` to `usize` and used `checked_add` before memory access.

=== 1.3 `VsockPacketRx::read_at_offset_from` (Line 344)
- *What it does*: Takes data from the Host and writes it into a Guest-provided buffer at a specific `offset`.
- *The Problem (Line 368)*: Similar to the TX path, it calculated the write address using `(offset + VSOCK_PKT_HDR_SIZE) as usize`.
- *Vulnerability*: An integer *overflow* here allows a guest to trick the host into writing data into unintended guest memory locations, leading to *Memory Corruption*.
- *Remediation*: Implemented `checked_add` on `usize` values with bounds validation.

== Side-by-Side Comparison
#grid(
  columns: (1fr, 1fr),
  gutter: 10pt,
  [*Pre-Fix (Vulnerable)*], [*Post-Fix (Secure)*],
  [
    ```rust
    // Line 235: Underflow risk
    if hdr.len > 
       self.buffer.len() - 44 
    { ... }
    ```
  ],
  [
    ```rust
    // Line 235: Secure Subtraction
    if hdr.len > self.buffer.len()
       .checked_sub(44)
       .ok_or(...)?
    { ... }
    ```
  ],
  [
    ```rust
    // Line 262: Overflow risk
    self.buffer.read_volatile_at(
        dst, 
        (offset + 44) as usize, 
        ...
    )
    ```
  ],
  [
    ```rust
    // Line 262: Secure Addition
    let start = (offset as usize)
        .checked_add(44usize)
        .ok_or(...)?;

    self.buffer.read_volatile_at(
        dst, start, ...
    )
    ```
  ]
)
#line(length: 100%, stroke: 0.5pt)
= 2. `csm/connection.rs` and `txbuf.rs` (Control Plane & Buffering)
*Rationale*: These files handle the protocol state machine and the buffering of outgoing data.

== Component Analysis

=== 2.1 `TxBuf::push` (`txbuf.rs` Line 53)
- *What it does*: Appends Guest data to the internal ring buffer when the Host-side socket is busy.
- *The Problem (Line 53)*: It performed a length check: `if self.len() + src.len() > Self::SIZE`.
- *Vulnerability*: The addition `self.len() + src.len()` can *overflow*. If it wraps to a small value, the check passes incorrectly, allowing an *Out-of-Bounds write* into the 64KB static buffer.
- *Remediation*: Replaced with safe subtraction: `if src.len() > Self::SIZE - self.len()`.

=== 2.2 `VsockConnection::peer_avail_credit` (Line 427)
- *What it does*: Calculates how much space is left in the peer's buffer to prevent flooding.
- *Analysis*: It uses `fwd_cnt` and `rx_cnt` (wrapping counters).
- *Result*: Kani proved that the implementation correctly uses `Wrapping<u32>`, making it immune to overflow panics during continuous 4GB+ transfers.

== Side-by-Side Comparison (`txbuf.rs`)
#grid(
  columns: (1fr, 1fr),
  gutter: 10pt,
  [*Pre-Fix (Vulnerable)*], [*Post-Fix (Secure)*],
  [
    ```rust
    // Line 53: Overflow risk
    if self.len() + src.len()
       > Self::SIZE
    {
        return Err(Error::Full);
    }
    ```
  ],
  [
    ```rust
    // Line 53: Secure Check
    if src.len() >
       Self::SIZE - self.len()
    {
        return Err(Error::Full);
    }
    ```
  ]
)

#line(length: 100%, stroke: 0.5pt)
= 3. `unix/muxer.rs` (Resource DoS Protection)
*Rationale*: The Muxer routes packets to host sockets. Errors here allow guests to exhaust host resources.

== Component Analysis

=== 3.1 `VsockMuxer::allocate_local_port` (Line 594)
- *What it does*: Generates a unique port number for a new host-side connection.
- *Result*: Kani proved the bitwise logic `(last + 1) & !(1 << 31) | (1 << 30)` is mathematically bound to the $[2^{30}, 2^{31})$ range, ensuring no port collisions.

=== 3.2 `VsockMuxer::add_connection` (Line 481)
- *What it does*: Limits the total number of active host connections.
- *Result*: Verified that `MAX_CONNECTIONS` (1023) is strictly enforced, preventing Host File Descriptor exhaustion.
#line(length: 100%, stroke: 0.5pt)
= 4. `event_handler.rs` (Availability & DoS)
*Rationale*: Handles asynchronous Epoll events. Panics here crash the entire Firecracker process.

== Component Analysis

=== 4.1 `handle_rxq_event` (Line 47) and `handle_txq_event` (Line 66)
- *What it does*: Reacts to VirtIO queue events by triggering packet processing.
- *The Problem (Lines 61, 81, 88)*: The code used `.unwrap()` on the result of queue processing: `self.process_rx().unwrap()`.
- *Vulnerability*: If a guest provides an invalid VirtIO ring index, `process_rx` returns an error. The `.unwrap()` call converts this error into a *Host Panic*, allowing a guest to *remotely shut down the VMM*.
- *Remediation*: Replaced all `unwrap()` calls with `match` blocks that log errors and continue safely.

=== 4.2 `MutEventSubscriber::process` (Line 192)
- *What it does*: The main event dispatch loop for the Vsock device.
- *The Problem (Line 203)*: Used `self.notify_backend(evset).unwrap()`.
- *Vulnerability*: Similar to above, a backend error would trigger a fatal host panic.
- *Remediation*: Graceful error propagation.

== Side-by-Side Comparison
#grid(
  columns: (1fr, 1fr),
  gutter: 10pt,
  [*Pre-Fix (Vulnerable)*], [*Post-Fix (Secure)*],
  [
    ```rust
    // Line 61: Crash path
    if self.process_rx().unwrap() {
        used_queues.push(...);
    }
    ```
  ],
  [
    ```rust
    // Line 61: Graceful recovery
    match self.process_rx() {
        Ok(true) => {
            used_queues.push(...);
        }
        Ok(false) => (),
        Err(err) => {
            error!("Vsock error: {:?}", err);
        }
    }
    ```
  ],
  [
    ```rust
    // Line 203: Dispatch panic
    Self::PROCESS_NOTIFY_BACKEND =>
        self.notify_backend(evset).unwrap(),
    ```
  ],
  [
    ```rust
    // Line 203: Safe dispatch
    Self::PROCESS_NOTIFY_BACKEND =>
        match self.notify_backend(evset) {
            Ok(uq) => uq,
            Err(e) => {
                error!("Error: {:?}", e);
                Vec::new()
            }
        },
    ```
  ]
)

#line(length: 100%, stroke: 0.5pt)
= 5. `persist.rs` (Snapshot Security)
*Rationale*: Restores device state from untrusted disk data.

=== 5.1 `Vsock::restore` (Line 72)
- *What it does*: Reconstructs the Vsock device from a `VsockFrontendState` snapshot.
- *Verification*: Proved that even with "Poisoned" values for CID or feature bits in the snapshot, the restoration logic either succeeds or returns an `Err`, but *never panics*.

= 6. Vsock Architecture & Data Flow
The following diagram illustrates the relationship between the verified components and the data path from Guest to Host.

#align(center)[
  #block(stroke: 1pt, inset: 1.5em, radius: 10pt, fill: luma(250))[
    #text(size: 1.2em, weight: "bold")[Logical Data Path Architecture] \
    #v(1em)

    #grid(
      columns: (1.5fr, 0.5fr, 1.5fr, 0.5fr, 1.5fr),
      align: horizon + center,

      [*1. Trigger*], [], [*2. Interface*], [], [*3. The Shield*],

      [#rect(fill: red.lighten(90%), radius: 4pt, inset: 8pt)[`event_handler.rs` \ (Epoll loop)]],
      [$arrow.r$],
      [#rect(fill: blue.lighten(90%), radius: 4pt, inset: 8pt)[`device.rs` \ (VirtIO Lifecycle)]],
      [$arrow.r$],
      [#rect(fill: orange.lighten(90%), radius: 4pt, inset: 8pt, stroke: 2pt + orange)[`packet.rs` \ (Binary Parsing)]],

      [], [], [], [], [],

      [*6. Output*], [], [*5. Buffer*], [], [*4. Control*],

      [#rect(fill: gray.lighten(90%), radius: 4pt, inset: 8pt)[Host UDS \ Sockets]],
      [$arrow.l$],
      [#rect(fill: green.lighten(90%), radius: 4pt, inset: 8pt)[`txbuf.rs` \ (Ring Buffer)]],
      [$arrow.l$],
      [#rect(fill: blue.lighten(95%), radius: 4pt, inset: 8pt)[`csm` & `muxer` \ (State & Ports)]],
    )

    #v(1.5em)
    #align(left)[
      *Data Flow Lifecycle:*
      + *Trigger*: `event_handler.rs` wakes up on IO readiness. (Remediated Guest-triggered panics).
      + *Interface*: `device.rs` manages the VirtIO queue state. (Verified activation consistency).
      + *The Shield*: `packet.rs` sanitizes raw Guest bytes. (Fixed 3 Arithmetic Security Bugs).
      + *Control*: `muxer.rs` routes to ports and `connection.rs` handles SYN/ACK. (Verified Resource Limits).
      + *Buffer*: `txbuf.rs` stores data if the host is busy. (Fixed Buffer Overflow).
      + *Time Machine*: `persist.rs` (not shown in flow) ensures the entire state can be safely reloaded.
    ]
  ]
]

#line(length: 100%, stroke: 0.5pt)
== Final Verification Summary
#table(
  columns: (2fr, 1fr, 1fr),
  inset: 10pt,
  align: horizon,
  [*Logic Group*], [*Finding*], [*Status*],
  [Packet Parsing], [3 Overflow/Underflow Bugs], [*FIXED & PROVEN*],
  [Event Handling], [3 Critical Panic Paths], [*FIXED & PROVEN*],
  [TX Buffering], [1 Integer Overflow Bug], [*FIXED & PROVEN*],
  [Credit Control], [Sound Wrapping Arithmetic], [*VERIFIED*],
  [Resource Limits], [Strict Connection Quotas], [*VERIFIED*],
  [Snapshot/Restore], [Robust against malformed data], [*VERIFIED*],
)

