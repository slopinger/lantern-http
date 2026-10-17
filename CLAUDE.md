# lantern-http
- Independent Haskell HTTP/1 wire library; public MIT project.
- Source: src/Lantern/HTTP.hs and src/Lantern/HTTP/Representation.hs. No transport, TLS, framework, or HTTP client dependency.
- Tests: nix build; nix flake check; nix develop -c cabal test --offline.
- Every parser failure poisons the connection; caller must close it.
- Preserve bounded allocation, unread pipelined bytes, strict framing, and streaming.
- Experimental; do not claim production security or complete RFC conformance.

- Representation helpers own bounded tag/date/precondition/range/multipart semantics;
  time is an explicit runtime dependency. Caller supplies whole-second metadata,
  trustworthy validator strength, file bytes and multipart boundary entropy.
- Preconditions precede range selection. HEAD ignores Range; If-Range requires
  strong evidence. Max 16 range elements; overlaps/adjacency merge with no duplicate
  bytes. Huge offsets use bounded arithmetic; unknown/malformed ranges are ignored.
- test/Representation.hs adds regression checks and 3,000 byte-oracle/length cases.

- HTTP line parsing accumulates bounded nonempty fragments and searches only new
  bytes plus a cross-fragment CR/LF boundary. Check size before concatenation;
  preserve unread pipeline bytes and bare-newline rejection. Failure/cancellation
  still requires connection closure. Do not reintroduce repeated prefix copying.
- Protocol tests now include exact/overflow line limits, CR/LF boundaries and
  1000 generated long-request/body/pipeline comparisons (12000 wire properties
  plus 3000 representation properties in total).
- `cabal bench fragmented --offline --enable-optimization=2` with benchmark options
  `+RTS -T -RTS` measures deterministic parser CPU/allocation. docs/fragmentation.md
  and its JSON preserve before/after/control/prototype observations. No network,
  peak-memory or general server throughput claim follows from these samples.

- Request-target validation is a bounds-checked ByteString index loop, preserving
  the previous grammar and raw percent escapes. Do not decode/normalize here.
  The previous list grammar is a separate test oracle: every one-byte suffix,
  percent edges and 3000 generated fragmented cases. Long request/pipeline tests
  use varied target bytes. Totals: 12000 wire + 3000 representation properties.
  docs/target-scan.md and JSON preserve three alternating revision pairs using
  the unchanged benchmark helper. These are long-target parser CPU/allocation
  observations, not ordinary-request/whole-server throughput or peak memory.

`readRequestMaybe` returns Nothing only for transport EOF before any next-request
byte. It preserves buffered/pipelined data and the strict readRequest grammar;
partial headers/lines and backend exceptions still fail. Consume the previous
body first and retain caller deadlines. TLS callers must supply authenticated
EOF from their TLS transport; this helper does not establish TLS closure itself.
Tests cover every proper nonempty prefix of a valid request across six fragment
widths, clean initial/pipeline boundaries and backend error propagation.
