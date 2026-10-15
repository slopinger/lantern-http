# HTTP research and implementation decisions

Reviewed 2026-10-15. This is a record of source-driven design and local tests,
not a security certification. Protocol behavior lives in this repository, rather
than in Warp, WAI, http-client, or an operating-system HTTP service.

## Sources and resulting design

[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), especially sections 2–7
and 11, is the framing reference. Message boundaries must be settled before a
connection is reused. Lantern rejects CL+TE, duplicate lengths, comma-joined
lengths, invalid transfer-coding chains, folded fields, and whitespace in names.
Every failure requires connection closure. These are deliberately strict choices;
no differential-parser recovery is attempted. Incoming chunked messages are
consumed through the terminal trailer block before the next request is parsed.

[RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) supplies method, field,
connection, status, and HEAD semantics. Lantern keeps request body framing
independent of the method. A proxy must regenerate framing and remove both named
hop fields and fields nominated by Connection. The server must separately handle
Host allowlists, forwarding identity, bodyless statuses, and authorization.
No-body response semantics take precedence over any representation length.

[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) describes a separate
multiplexed protocol, not a header-parser upgrade. Supporting it requires stream
state, flow control, header compression limits, and resource accounting. This
release explicitly implements HTTP/1; it must never advertise h2 through ALPN.

## Threat model

Remote clients control every input byte, can fragment at any boundary, pipeline
messages, announce huge decimal/hex sizes, stop mid-message, and race deadlines.
An upstream is also untrusted wire input. Configuration and the transport adapter
are trusted. The callback must limit each received chunk (the server uses 16 KiB)
and apply absolute deadlines rather than resetting a timer for every received
byte. The library bounds metadata independently of decoded body bytes.

A Reader owns a strict ByteString buffer. Reading a line retains the suffix,
which prevents losing the start of a pipelined request. Fixed bodies consume
only their declared count. Chunk sizes are arbitrary-precision integers bounded
by syntax before accumulation, and application limits are checked before reading
a payload. `readBody` emits existing bounded pieces rather than allocating a
chunk-sized buffer. `collectBody` intentionally buffers and copies a bounded body;
server admission limits must account for that peak memory.

## Validation strategy

A correct result must survive every tested transport split, not just one complete
buffer. The regression suite feeds complete request/body/pipeline combinations
at widths 1–128. Invalid framing, CR/LF syntax, oversized metadata, forbidden
trailers, truncated chunks, and invalid targets have rejection cases. Randomized
properties exercise arbitrary fixed bodies and arbitrary parser input. These
properties establish behavior for generated inputs; they do not prove absence of
parser ambiguities. End-to-end proxy tests belong to the server repository.

## Remaining limitations

No formally verified grammar, coverage-guided native fuzzer, independent audit,
HTTP/2, upgrade/tunnel support, or generic URI parser. Chunk extensions are treated
as bounded printable opaque metadata, a narrower validation effort than the full
extension grammar. Trailers are discarded after validation. Callers must never
merge them into request headers. Cookie/authentication policy and cache semantics
remain application responsibilities. Never expose a successful test count as a
security guarantee.
