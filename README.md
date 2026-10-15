# lantern-http

An independent, experimental HTTP/1 wire library written in Haskell. Runtime
dependencies: `base` and `bytestring`. There is no HTTP server/client framework
underneath it. MIT licensed. Used by [Lantern](https://git.freifick.net/slop/lantern).

```haskell
reader <- newReader receiveBytes
request <- readRequest reader
body <- collectBody reader (reqFraming request) 1048576
writeHead sendBytes 200 [("content-length", "2")]
sendBytes "ok"
```

`receiveBytes` supplies bounded chunks and returns empty bytes at EOF. One reader
belongs to one connection and preserves unread pipelined bytes. Do not use it
concurrently. Callers own transport, absolute deadlines, admission limits, Host
routing, and connection closure. After any `ProtocolError`, close the connection;
never resume parsing it. Header names are normalized to lowercase.

`readBody` streams decoded fixed/chunked/close-delimited bodies to a callback.
`collectBody` is for bounded request bodies. `readResponse` skips at most eight
informational responses and uses the request method to handle HEAD. `stripHop`
removes standard and Connection-nominated hop fields; proxy callers must generate
fresh framing and forwarding headers. `writeHead` validates emitted fields.

Limits: 8 KiB start/field lines, 32 KiB/100 header fields, 8 KiB/32 trailers,
64 KiB cumulative chunk metadata; caller supplies a decoded-body byte cap. Strict
choices include rejecting duplicate Content-Length even when equal, CL+TE,
obsolete folding, whitespace before colons, unsupported transfer codings, and
non-origin request targets. HTTP/1.0 requests require Host and cannot use chunked
encoding. HTTP/2, CONNECT tunnels, protocol upgrades, and content decompression are
outside this library. Chunk extensions are bounded printable metadata and ignored;
trailers are validated and discarded, never merged into headers.

```sh
nix build
nix flake check
nix develop -c cabal test --offline
```

The tests exercise 128 fragmentation widths, pipelining, framing regressions,
upstream heads, and 8,000 randomized properties. These checks are not an audit or
proof of complete RFC conformance. See [research and threat model](docs/research.md).
