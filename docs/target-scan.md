# Request-target scan observations, 2026-10-16

The existing fragmentation helper and its compiler/RTS settings are unchanged.
The baseline is `c9a0b57`; the only implementation change is replacing the target
validator's byte-to-list conversion with an indexed ByteString scan. Each trial
parses the same 8135-byte request, including 8100 target padding bytes. Three
alternating before/after pairs give these median process CPU seconds and total
RTS allocation (the allocations repeat exactly for each implementation/case):

| Receive bytes | Requests | Before allocated | After allocated | Before CPU s | After CPU s |
| --- | --- | --- | --- | --- | --- |
| 1 | 100 | 189,872,576 | 157,079,776 | 0.074493 | 0.072982 |
| 128 | 1000 | 349,601,928 | 21,673,928 | 0.107708 | 0.081479 |
| 16384 | 10000 | 3,292,484,144 | 13,204,144 | 1.038380 | 0.737323 |

[Every trial](target-scan-2026-10-16.json) includes the initial after run, baseline
revision, source/helper hashes and build flags. The previous fragmentation report
remains a separate dated observation. GC and source-list preparation follow that
helper's documented method; CPU includes the final GC. This is heap allocation,
not peak live memory, and parser work without sockets/TLS/files. The target is
unusually long: this is not an ordinary-request or whole-server throughput claim.
There is no new Caddy comparison, affinity pinning or security audit here.

The accepted grammar is unchanged. Percent escapes still require exactly two
hexadecimal bytes; raw target bytes are preserved. Bounds precede each index.
Tests compare against the previous list grammar, check every single-octet suffix,
valid/invalid/truncated percent sequences and 3000 generated cases with fragmented
reads. Existing long request/body/pipeline cases now vary their target bytes so
reordered fragments cannot hide in a uniform padding pattern.
