# Vsock Verification — Review Notes (Group 4)

> Status: **draft for review.** Nothing in the existing `packet.rs`, `KANI_VERIFICATION.md`,
> or `vsock_flow_diagrams.md` has been modified. This document records the analysis and the
> proposed corrections so they can be reviewed before being applied.

---

## 1. Headline findings

1. The "failed harness" overflow (`offset + 44` when `count == 0`) is a **real arithmetic
   fact about the function in isolation, but it is NOT reachable through the call graph.**
   `offset` is never guest-controlled to be large.
2. The current `KANI_VERIFICATION.md` **overstates exploitability** — it claims a malicious
   guest can trigger it via a crafted `fwd_cnt`/`offset`. `offset` is not derived from any
   header field.
3. **Harnesses 5, 7, and 8 do not call the functions they claim to verify** — they
   re-implement the logic inline and assert on the copy. They prove a model, not the code.
4. The current harness 8 **code contradicts the doc**: the code models the *fixed* control
   flow (should PASS), while the doc says harness 8 FAILS.
5. The real attack surface — `parse()` and the credit arithmetic — currently has **no
   harness**.

---

## 2. Reachability analysis of the `count == 0` overflow

### 2.1 The arithmetic

In both `write_from_offset_to` (`packet.rs:245`) and `read_at_offset_from` (`packet.rs:354`),
the unguarded expression is:

```rust
(offset + VSOCK_PKT_HDR_SIZE) as usize     // VSOCK_PKT_HDR_SIZE == 44
```

This overflows `u32` only when `offset > u32::MAX - 44`. Before the fix, when `count == 0`
the bounds guard `count > buf.len().saturating_sub(44).saturating_sub(offset)` evaluates
`0 > X`, which is always false, so it never fires and control reaches the addition.

### 2.2 Every production call site

| Location | Call | `offset` arg | `count` arg |
|---|---|---|---|
| `connection.rs:221` | `read_at_offset_from(&mut self.stream, 0, max_len)` | **0** | `max_len` |
| `connection.rs:614` | `write_from_offset_to(&mut self.tx_buf, 0, len)` | **0** | `len` |
| `connection.rs:619` | `write_from_offset_to(&mut self.stream, 0, len)` | **0** | `len` |
| `connection.rs:642` | `write_from_offset_to(&mut self.tx_buf, written, len - written)` | **`written`** | `len - written` |
| `connection.rs:952` | `read_at_offset_from(&mut data, 0, len)` | **0** | `len` |
| `muxer.rs:892` | `read_at_offset_from(&mut data, 0, data_len)` | **0** | `data_len` |

### 2.3 Why none of them can overflow

- **Five of six sites pass `offset = 0`** → `0 + 44 = 44`. Safe for any `count`.
- **The only non-zero site, `connection.rs:642`**, is reached from `send_bytes`
  (`connection.rs:605-642`):
  - `len = pkt.hdr.len()`, and `parse()` (`packet.rs:231`) rejects any packet with
    `hdr.len > MAX_PKT_BUF_SIZE` (64 KiB). ⇒ `len ≤ 65536`.
  - `written` is the prior write's return, capped at `count = len`. ⇒ `written ≤ len ≤ 65536`.
  - The call is guarded by `if written < len`, so `count = len - written ≥ 1` (never 0 here).
  - ⇒ `offset + 44 ≤ 65580 ≪ u32::MAX`. **No overflow possible.**

**Conclusion:** the `count == 0 && offset ≈ u32::MAX` case the harness explores is produced
only by feeding `kani::any()` into `offset` — an input the real code never generates. This is
a **defensive robustness gap**, not a live vulnerability.

---

## 3. Can the bug be "simulated as an attacker"?

**Through a guest packet: NO.** No packet field is routed into the `offset` argument. The
guest controls `hdr.len`, `buf_alloc`, `fwd_cnt`, etc., but:
- `hdr.len` is clamped to ≤64 KiB by `parse()` before it can ever become a `count`.
- `offset` is computed internally (`0` or `written`), never copied from a header field.

**Through a direct call: YES** — and this is the honest demonstration. With the
`if count == 0 { return Ok(0); }` guard removed:

```rust
let pkt = /* any parsed TX packet */;
let mut sink = std::io::sink();
// offset huge, count zero: guard `0 > X` never fires → falls through to (offset + 44)
let _ = pkt.write_from_offset_to(&mut sink, u32::MAX, 0); // debug build: panics on overflow
```

### Recommended framing for the report

> Kani found the function is unsafe for arbitrary inputs (`offset ≈ u32::MAX`, `count == 0`).
> We confirmed via call-site analysis that no current caller supplies such inputs, so it is
> **not remotely exploitable**. The fix is nonetheless justified as **defense-in-depth**: the
> function's contract should not silently depend on caller discipline.

Avoid claiming guest-triggered DoS — it is not supported by the code.

---

## 4. Harness-by-harness necessity assessment

| # | Harness | Verdict | Reason |
|---|---|---|---|
| 1 | `header_all_fields_roundtrip` | **Weak** | Proves `from_le(to_le(x)) == x`, a std guarantee. Wouldn't catch a setter/getter both touching the wrong field (round-trips fine). |
| 2 | `set_flag_is_or` | **Weak** | Verifies one line `flags() \| flag`; correct by inspection, no nondeterminism. |
| 3 | `pkt_hdr_size_constant` | **Redundant** | Duplicates unit test `test_packet_hdr_size` (`packet.rs:642`); a `const` assertion needs no model checker. |
| 4 | `tx_buf_size_no_underflow` | **Medium** | Real invariant, but tautological — *assumes* `buf_len ≥ 44` instead of proving `parse()` establishes it. |
| 5 | `write_..._nonzero_count_no_overflow` | **Flawed** | Does **not** call `write_from_offset_to`; re-implements the guard inline. Proves a model. |
| 6 | `rx_buf_size_no_underflow` | **Medium** | Same as #4 for RX. |
| 7 | `read_..._nonzero_count_no_overflow` | **Flawed** | Same as #5 — re-implements `read_at_offset_from`. |
| 8 | `write_zero_count_overflow_finding` | **Flawed + stale** | Re-implements control flow; code models the *fixed* flow (PASS) but doc says FAIL. |

### Structural problem

Harnesses 5/7/8 give **false confidence**: because they duplicate the arithmetic rather than
calling the real functions, a future change to `write_from_offset_to`/`read_at_offset_from`
would leave them passing against a stale copy. A proper harness constructs a Kani-backed
buffer and calls the actual method with `kani::any()` offset/count — that is what would
*verify the fix in situ* and justify Kani over a plain unit test.

### Doc/code contradiction to reconcile (harness 8)

- `packet.rs:588-611` models the **fixed** control flow (has the `if count == 0` branch) ⇒ PASSES.
- `KANI_VERIFICATION.md` §5/§6 says harness 8 **FAILS** and documents the bug.

Pick one consistent story:
- **(a)** Keep the fix; rewrite harness 8 to *call the real (fixed) function* with arbitrary
  inputs; update the doc to "8/8 pass."
- **(b)** Keep a harness that calls the *unfixed* function to genuinely reproduce the failure,
  and clearly mark it as the "before" state.

Option (a) is the stronger result.

---

## 5. Higher-value harness targets in the vsock flow

In priority order — none of these are currently covered:

1. **`VsockPacketTx::parse()` / `VsockPacketRx::parse()`** (`packet.rs:212`, `:310`). The real
   boundary where guest header bytes are interpreted. A harness over arbitrary header bytes +
   arbitrary `buffer.len()` proving "no panic, and `buffer.len() - 44` at `packet.rs:235` never
   underflows" directly fulfils proposal Objective 1.
2. **Credit / flow-control arithmetic** — `peer_avail_credit()` (`connection.rs:664`) and
   `peer_needs_credit_update()` (`:651`), computed on guest-supplied `peer_buf_alloc` /
   `peer_fwd_cnt` (`connection.rs:296-297`). They use `Wrapping` (won't panic) but a wrapped
   value feeds `max_len = min(buf_size, peer_avail_credit)` (`connection.rs:218`). Worth proving
   the value stays sane or documenting that the `min` neutralizes it.
3. **`TxBuf` ring buffer** (`txbuf.rs`) — `push`/`flush_to` with wrapping `head`/`tail` and
   `% SIZE` offsets (`txbuf.rs:62,97`). Index arithmetic, attacker-paced; aligns with "no
   buffer overflows / resource leaks."
4. **State machine** (`csm/connection.rs`) — proposal Objective 2 (micro-firewall). The
   property "a blocked port can never reach `Established`" is a reachability question, a much
   stronger result than the parser arithmetic.

---

## 6. Proposed corrections to `vsock_flow_diagrams.md` (Diagram 2)

Not yet applied — listed for review:

1. Node `N` currently reads *"offset & count derived from guest-supplied buf_alloc / fwd_cnt."*
   **`offset` is not** — it is `0` or `written`. Only `count` is (indirectly, and clamped).
   Proposed: *"count derived from validated hdr.len / credit (≤ 64 KiB); offset is always 0 or
   `written` (≤ 64 KiB) — never attacker-large."*
2. The red `BUG` box currently says *"guest-triggered DoS."* Proposed: *"Reachable only via a
   direct call with offset ≈ u32::MAX; NOT reachable from any guest packet. Fixed as
   defense-in-depth."*

---

## 7. Draft: a harness that actually calls `parse()` (Objective 1)

Sketch for review — exercises the real parser over arbitrary guest input rather than a model.
Construction of a Kani-backed `IoVecBuffer`/`GuestMemoryMmap` will need the same scaffolding
already used by the existing `iovec.rs` harnesses; this is the shape, not final code:

```rust
#[kani::proof]
fn verify_tx_parse_no_panic() {
    // Arbitrary buffer length, bounded to keep the model tractable.
    let buf_len: u32 = kani::any();
    kani::assume(buf_len <= defs::MAX_PKT_BUF_SIZE + VSOCK_PKT_HDR_SIZE);

    // Build a TX packet whose backing buffer reports `buf_len` and whose first
    // 44 bytes (the header) are unconstrained (kani::any() bytes).
    let mut pkt = make_tx_packet_with_arbitrary_header(buf_len);

    // The property: parse-equivalent validation must never panic and must
    // uphold the post-condition that, on Ok, buffer.len() >= VSOCK_PKT_HDR_SIZE
    // so buf_size() cannot underflow.
    if pkt.hdr.len() <= defs::MAX_PKT_BUF_SIZE
        && pkt.hdr.len() <= buf_len.saturating_sub(VSOCK_PKT_HDR_SIZE)
        && buf_len >= VSOCK_PKT_HDR_SIZE
    {
        let _ = pkt.buf_size();          // must not underflow
        let mut sink = std::io::sink();
        let _ = pkt.write_from_offset_to(&mut sink, 0, pkt.hdr.len()); // must not panic
    }
}
```

The decisive improvement over harnesses 5/7/8: it **invokes the production method**, so it
will keep verifying the real code (and the fix) as the implementation evolves.

---

## 8. Suggested next actions (for you to approve)

- [ ] Apply the two Diagram 2 corrections in `vsock_flow_diagrams.md` (§6).
- [ ] Reconcile harness 8 — choose option (a) or (b) in §4 and update both code and doc.
- [ ] Correct the exploitability wording in `KANI_VERIFICATION.md` §6 to the defense-in-depth
      framing (§3).
- [ ] Replace/augment harnesses 5/7/8 with versions that call the real functions.
- [ ] Add a `parse()` harness (§7) to genuinely cover proposal Objective 1.
