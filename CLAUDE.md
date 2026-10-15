# lantern-http
- Independent Haskell HTTP/1 wire library; public MIT project.
- Source: src/Lantern/HTTP.hs. No transport, TLS, framework, or HTTP client dependency.
- Tests: nix build; nix flake check; nix develop -c cabal test --offline.
- Every parser failure poisons the connection; caller must close it.
- Preserve bounded allocation, unread pipelined bytes, strict framing, and streaming.
- Experimental; do not claim production security or complete RFC conformance.
