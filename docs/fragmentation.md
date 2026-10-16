# Fragmented line observations, 2026-10-16

The fixed wire is one valid 8,135-byte request containing an 8,100-byte target
padding. Each trial parses it repeatedly through the library's real Reader with
prebuilt receive fragments. The helper verifies target length/framing and that
all source fragments were consumed. It does not use sockets, TLS or file I/O.

GHC 9.10.3, `cabal bench fragmented --offline --enable-optimization=2`, `+RTS -T`.
Fragment lists are forced before measurement; GC runs before/after each case so
RTS allocated-byte deltas include the measured loop. CPU is process CPU time,
including the final GC; it is not wall time or latency. Allocation is total heap
allocation, not live/peak RSS. The shared VM has no CPU affinity pinning here.

The comparison uses three alternating before/after process pairs. Baseline is
`b2d8ccb` with the identical benchmark helper copied into a detached worktree;
final source/helper SHA-256 values and every observed trial are in
[the JSON](fragmentation-2026-10-16.json). Initial and prototype observations,
including the less favorable coalesced control, are retained too.

Allocated bytes are identical across repeated runs of each implementation/case;
CPU columns are the median of the three final pairs (seconds).

| Receive bytes | Requests | Before allocated | After allocated | Before CPU s | After CPU s |
| --- | --- | --- | --- | --- | --- |
| 1 | 100 | 3,535,841,928 | 189,872,576 | 5.510307 | 0.074775 |
| 128 | 1000 | 611,190,776 | 349,601,928 | 0.538519 | 0.110566 |
| 16384 | 10000 | 3,292,004,128 | 3,292,484,144 | 1.037236 | 1.061967 |

Single-byte fragmentation avoids repeated prefix copies/scans and shows a large
reduction. The 128-byte case improves too. The whole-buffer long-line control
used about 2.4% more CPU in these final pairs and allocated 48 extra bytes per
request. These observations do not establish an ordinary-server throughput improvement.
Fragment-list metadata is bounded by the pending byte limit, and can be larger
than one contiguous pending buffer. Absolute deadlines and admission are still
required. No general Caddy comparison, TLS/WAN result or security proof is claimed.

Reproduce with the command from the README. To compare revisions, build the same
helper at each source revision with the same compiler/optimization/RTS flags,
then alternate executions. Do not compare different helper versions or turn
under-tracing timing into a throughput claim.
