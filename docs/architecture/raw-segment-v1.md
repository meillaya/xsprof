# Compact raw segment v1 (xsprof/raw-segment/v1)

The recorder stores raw events in compact, append-only .xsraw segments. This is
storage, not a wire protocol: every extraction path still emits canonical
`xsprof/event/v1` NDJSON, and the event schema is unchanged.

## Layout

All integers are little-endian. Checksums are CRC-32C (Castagnoli).

    header 64 B: magic[8]="XSPRAWS1" | u16 version=1 | u16 header_len=64 |
                 u32 flags=0 | u32 seq | u32 block_payload_max=32768 |
                 u64 start_wall_ns | u64 start_mono_ns | u64 reserved |
                 u64 reserved | u32 header_crc32c | u32 reserved
    block 8 B + payload: u8 type (1=events, 2=footer) | u8 flags=0 |
                 u16 payload_len | u32 payload_crc32c
    footer payload 24 B: u64 event_count | u64 block_count | u64 encoded_bytes
    record: u8 kind (0..17) | u8 flags (1 pid==tid, 2 comm, 4 detail,
                 8 ts_absolute, 16 comm_new) |
            ts (uvarint absolute on the first record of a block, otherwise
                zigzag uvarint delta) | cpu zigzag | pid zigzag |
            tid zigzag unless pid==tid | a,b,c uvarint |
            comm (comm_new: uvarint len 1..15 + bytes, else uvarint 1-based
                  block-table index) |
            detail (uvarint len 1..1024 + bytes, only when flag set)

The comm string table is per events block (cap 1024 entries) and resets on
every block, so a block never depends on earlier blocks. The encoder asks the
writer to start a new block on a full table or an unrepresentable timestamp
delta. Maximum record size is 1152 B; maximum block payload is 32768 B.

## Privacy and round-trip identity

Strings are stored after exactly the transform `event.writeJson` applies
(`privacy.boundComm` <= 15 printable bytes, `privacy.redactDetail` <= 1024
printable bytes). A secret is therefore never written to the state directory,
and decoding then serializing reproduces canonical NDJSON byte for byte. The
committed golden pair under `tests/golden/recorder/` pins this identity.

## Clean close, torn tail, corruption

- The header is written at create time.
- Whole blocks are the write unit; `close()` appends the footer block and
  fsyncs the file.
- A missing footer means a crash or a torn write: the reader decodes every
  complete block before the tail and reports `dirty`. `capture` emits
  `capture_truncated_tail missing_footer=1 dropped=1`.
- A bad block CRC or malformed record stops decoding at that block and reports
  `corrupt`; `capture` emits `capture_corrupt_segment offset=N dropped=1`.
  There is no resync and no interpolation.
- An unsupported version is refused loudly (`capture_unsupported_segment`),
  never guessed.
- The daemon restart path checks only the final footer block (see
  `segment_reader.tailStatus`), so recovery does not re-read the segment.

Worst torn-write loss is one block (at most ~2.5k events at the measured
compact size); a corrupted block loses the remainder of that segment, which
rotates at 16 MiB or 30 s.

## Legacy compatibility

`.ndjson` segments from 0.3 and earlier remain readable forever through the
line path in `recorder/extract.zig`. The manifest's optional `raw_codec`
and per-segment `codec` fields record the format; when absent (0.3
manifests) the path suffix decides. A mixed state directory after an upgrade
is supported and tested.

Downgrade is one-way: a 0.3 binary can parse the added manifest fields but
cannot decode .xsraw, so use a new state directory when downgrading.

## Verification

`xsprof verify --dir STATE [--json]` decodes every segment with the same
reader extraction uses and reports clean/dirty/corrupt/missing/unsupported.
Exit 0 only for READY. `qa/compact_roundtrip.sh` covers clean, corrupt, torn,
mixed, and unsupported-version states without perf privileges.
