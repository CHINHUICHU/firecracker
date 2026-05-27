# Firecracker Vsock — Data Flow & Verification Motivation

Three diagrams in order of zoom level:
1. **System architecture** — trust boundary & attack surface
2. **Packet parser internals** — step-by-step flow with the exact bug location
3. **Connection state machine** — where the micro-firewall is inserted

Render with any Mermaid-compatible viewer (GitHub, VS Code Mermaid Preview, Obsidian, etc.).

---

## Diagram 1 — System Architecture & Trust Boundary

```mermaid
flowchart LR
    subgraph G["🖥  Guest VM  (UNTRUSTED)"]
        direction TB
        app["Guest App\nAF_VSOCK socket"]
        drv["Linux Kernel\nVirtio-Vsock Driver"]
        app <--> drv
    end

    subgraph Q["Shared Memory\n(virtio queues)"]
        direction TB
        txq[/"TX Queue\nguest → host"/]
        rxq[/"RX Queue\nhost → guest"/]
    end

    drv -->|"guest-controlled\npacket bytes"| txq
    rxq --> drv

    subgraph V["🔥  Firecracker VMM  (TRUSTED)"]
        direction TB

        eh["event_handler.rs\nepoll loop"]

        subgraph P["packet.rs  ◄ Kani Harnesses 1–8"]
            pa["parse()\nread & validate header\nfrom guest memory"]
            pw["write_from_offset_to()\nTX: guest → host"]
            pr["read_at_offset_from()\nRX: host → guest"]
            pa --> pw & pr
        end

        subgraph C["csm/connection.rs  ◄ Micro-Firewall Target"]
            sm["VsockConnection\nstate machine"]
        end

        mx["unix/muxer.rs  VsockMuxer\nmax 1,023 simultaneous connections\nkeys connections by (host_port, guest_port)"]

        eh --> pa
        pw & pr --> sm --> mx
    end

    subgraph H["🏠  Host  (TRUSTED)"]
        hs["Host Process\nAF_UNIX socket"]
    end

    txq -->|epoll event| eh
    mx <-->|"proxied\ndata"| hs
    mx -->|"fill RX\nbuffer"| rxq

    style G fill:#fff0f0,stroke:#e03131
    style P fill:#fff9db,stroke:#f08c00
    style C fill:#ebfbee,stroke:#2f9e44
```

---

## Diagram 2 — Packet Parser: Internal Flow & Bug Location

The parser runs entirely inside the VMM but operates on memory written by the (untrusted) guest.
Fields like `offset` and `count` are derived from guest-supplied header values (`fwd_cnt`, `buf_alloc`).

```mermaid
flowchart TD
    A(["Guest writes packet to virtio TX queue"])
    B["event_handler.rs\nepoll notification fires"]
    C["device.rs\npop DescriptorChain from TX queue"]
    D["load_descriptor_chain()\nmap guest memory → IoVecBuffer\n⚠ zero-copy: direct pointer into guest RAM"]
    E["read 44-byte VsockPacketHeader\nfrom guest memory\n(src_cid, dst_cid, src_port, dst_port, len, op, flags, buf_alloc, fwd_cnt)"]

    F{"buf_len < 44?"}
    G(["Err: DescChainTooShortForHeader\ndrop packet"])

    H{"hdr.len >\nMAX_PKT_BUF_SIZE\n(64 KiB)?"}
    I(["Err: InvalidPktLen\ndrop packet"])

    J{"hdr.len >\nbuf_len − 44?"}
    K(["Err: DescChainTooShortForPacket\ndrop packet"])

    L["VsockPacketTx ready\nhdr cached in hypervisor memory\nno more guest memory reads needed"]

    M["csm/connection.rs\nsend_pkt(pkt)\nforward data to host Unix socket"]

    N["write_from_offset_to(dst, offset, count)\noffset & count derived from\nguest-supplied buf_alloc / fwd_cnt"]

    O{"count == 0?\n← early-exit guard\n(the fix)"}
    P(["return Ok(0)  ✅\nsafe: no arithmetic on offset"])

    Q{"count >\nbuf_len − 44 − offset?"}
    R(["Err: GuestMemoryBounds\ndrop"])

    S["compute index:\n(offset + 44) as usize\n✅ count > 0 and guard passed\n   → offset ≤ MAX_PKT_BUF_SIZE\n   → offset + 44 ≤ 65,580 ≪ u32::MAX\nno overflow possible"]

    T(["writev() to host AF_UNIX socket\ndata delivered"])

    BUG["⚠ BUG FOUND BY KANI  (Harness 8)\n\nPRE-FIX: no count == 0 check\n\ncount = 0  →  guard '0 > X' is always false\n             guard never fires for any offset\n             falls through to (offset + 44) as usize\n\noffset = u32::MAX  →  u32 OVERFLOW\n  debug build:   panic!  →  process abort  →  guest-triggered DoS\n  release build: silent wrap  →  wrong index"]

    A --> B --> C --> D --> E --> F
    F -->|yes| G
    F -->|no| H
    H -->|yes| I
    H -->|no| J
    J -->|yes| K
    J -->|no| L --> M --> N --> O
    O -->|yes| P
    O -->|no| Q
    Q -->|yes| R
    Q -->|no| S --> T

    N -. "count=0 path\nbefore fix" .-> BUG

    style BUG fill:#e03131,color:#fff,stroke:#c92a2a,stroke-width:2px
    style P fill:#2f9e44,color:#fff,stroke:#2b8a3e
    style S fill:#2f9e44,color:#fff,stroke:#2b8a3e
    style D fill:#fff3bf,stroke:#f59f00
    style N fill:#fff3bf,stroke:#f59f00
```

---

## Diagram 3 — Connection State Machine & Micro-Firewall Hook

The state machine in `csm/connection.rs` drives every individual vsock connection.
The micro-firewall is inserted in the `PeerInit` state — **before** `Established` is reached —
so restricted ports can never complete a handshake.

```mermaid
stateDiagram-v2
    direction LR

    [*] --> LocalInit  : HOST initiates\nconnect(uds_path)\nsend "CONNECT port\n"
    [*] --> PeerInit   : GUEST initiates\nVSOCK_OP_REQUEST packet

    LocalInit --> Established : guest responds\nVSOCK_OP_RESPONSE ✅

    PeerInit --> Established : dst_port ALLOWED\nFirecracker sends\nVSOCK_OP_RESPONSE ✅
    PeerInit --> Killed      : 🔒 dst_port BLOCKED\nMicro-Firewall check fails\nFirecracker sends VSOCK_OP_RST

    Established --> LocalClosed  : host AF_UNIX\nsocket closed
    Established --> PeerClosed   : guest sends\nVSOCK_OP_SHUTDOWN\n(flags: RCV / SEND)
    Established --> Killed       : RST received\nor timeout

    LocalClosed --> Killed : flush + RST
    PeerClosed  --> Killed : flush + RST\nexchange complete

    Killed --> [*] : removed from\nVsockMuxer HashMap
```

---

## Summary: Why Formal Verification?

| Layer | What can go wrong | Testing coverage gap | Kani/Verus target |
|---|---|---|---|
| **packet.rs** parser | Integer overflow on `offset + 44` when `count = 0` | Fuzzing unlikely to hit exactly `count=0 && offset≈u32::MAX` | Harnesses 4–8 |
| **packet.rs** header | LE encoding round-trip data loss; wrong `VSOCK_PKT_HDR_SIZE` constant | Unit tests use fixed values, miss all-bits-set edge cases | Harnesses 1–3 |
| **csm/connection.rs** micro-firewall | Port filter bypassed via state transition edge cases | Hard to enumerate all state/packet orderings with tests | Kani / Verus proof |

The key insight: a malicious guest can craft packet headers with arbitrary field values.
Kani explores **all possible u32 inputs simultaneously** and proves the arithmetic is safe — something no finite test suite can do.
