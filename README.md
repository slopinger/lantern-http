# lantern-http

An independent, experimental HTTP/1 wire library written in Haskell. Runtime
dependencies: `base`, `bytestring`, and `time`. There is no HTTP server/client framework
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
routing, and connection closure. After a parse failure (including `ProtocolError`)
or cancellation, close the connection; never resume parsing it. Header names are
normalized to lowercase.

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
upstream heads, 12,000 wire properties, and 3,000 representation/range properties. These checks are not an audit or
proof of complete RFC conformance. See [research and threat model](docs/research.md).

`Lantern.HTTP.Representation` provides bounded entity-tag parsing, HTTP dates
(including both obsolete forms and the 50-year rule), ordered precondition
checks, byte-range selection, coalescing, and multipart prefixes/exact lengths.
It accepts validators for an existing representation and normalized header names;
callers own file metadata, validator strength, body I/O, and boundary entropy.
Supply `modifiedAt` at whole-second HTTP precision. If-Match uses strong comparison;
If-None-Match uses weak comparison. If-Range requires a matching strong validator.

Range decimals are processed without machine-integer overflow. Unknown/malformed
ranges fall back to the full response; unsatisfiable or excessive requests are
rejected. At most 16 comma-separated range elements are accepted, overlaps and
adjacency are coalesced, and disjoint groups retain first-requested order. HEAD
ignores Range. Preconditions must be evaluated before `selectRanges`. Multipart
writers validate boundaries/media metadata and return an exact length without
buffering representation data. Callers stream each prefix, the chosen file bytes,
CRLF, then the closing delimiter.

Line parsing searches only newly received fragments plus the possible CR/LF
boundary, then concatenates once after checking the byte limit. Fragment metadata
is bounded by the pending line bytes because each receive must be nonempty.
Complete lines already in one buffer retain their slice path.

To reproduce the CPU/allocation experiment (no sockets or TLS):

```sh
nix develop -c cabal bench fragmented --offline --enable-optimization=2 --benchmark-options='+RTS -T -RTS'
```

The helper verifies parsed results before reporting process CPU time and RTS
allocation. See [the observations](docs/fragmentation.md) and complete raw trials;
this is a long-line parser workload, not a server throughput result.

Request-target validation scans the original ByteString with checked indices,
avoiding a per-byte list while retaining the same grammar and raw escapes.
[Target-scan measurements](docs/target-scan.md) use the existing long-request
helper and retain every before/after trial.

`readRequestMaybe` returns Nothing only for transport EOF before any next-request
byte. It preserves buffered/pipelined data and the strict readRequest grammar;
partial headers/lines and backend exceptions still fail. Consume the previous
body first and retain caller deadlines. TLS callers must supply authenticated
EOF from their TLS transport; this helper does not establish TLS closure itself.
Tests cover every proper nonempty prefix of a valid request across six fragment
widths, clean initial/pipeline boundaries and backend error propagation.

Responses with an HTTP/1.0 status line and any Transfer-Encoding are rejected
as faulty framing (502), before body suppression or informational skipping.
HTTP/1.0 fixed/close-delimited responses and HTTP/1.1 chunked responses remain
supported. Fragmented regressions cover GET, HEAD, 304 and informational status
cases, alongside valid framing/body controls.

Lantern.HTTP.Encoding exposes encodingPreferences for content-coding negotiation:
rank supported names by bounded integer qvalues, server order on ties, identity
fallback unless explicitly weighted/excluded. Absent Accept-Encoding accepts all
offers, an empty field only identity. Wildcard exclusions and explicit preferences
are honored; malformed/duplicate values or more than 128 items fail. No codecs
or transport dependencies are added. Existing representation checks cover normal
weighting, identity, exclusion and an invalid value without another test suite.
