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
  1000 generated long-request/body/pipeline comparisons (9000 wire properties
  plus 3000 representation properties in total).
- `cabal bench fragmented --offline --enable-optimization=2` with benchmark options
  `+RTS -T -RTS` measures deterministic parser CPU/allocation. docs/fragmentation.md
  and its JSON preserve before/after/control/prototype observations. No network,
  peak-memory or general server throughput claim follows from these samples.
