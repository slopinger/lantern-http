# HTTP research and implementation decisions

Reviewed 2026-10-16. This is a record of source-driven design and local tests,
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
merge them into request headers. Cookie/authentication policy, cache storage and validator generation
remain application responsibilities. Never expose a successful test count as a
security guarantee.

## Conditional and partial representations

[RFC 9110 sections 8.8, 13 and 14](https://www.rfc-editor.org/rfc/rfc9110.html)
were checked for precondition ordering, weak/strong comparisons, date formats,
If-Range exact matching, and byte-range syntax. The API treats these as separate
steps so a 304/412 decision precedes range processing. Empty entity-tag lists are
valid; quoted commas remain inside tags. Dates use the standard time primitives
with our HTTP syntax/obsolete-year handling. Invalid or repeated date fields are
ignored. Invalid tag syntax is reported to the application.

Our range policy caps comma elements at 16 and tag/empty-element counts at 128.
Numeric validation compares arbitrary-width decimal strings, then clamps arithmetic
to representation size plus one. Overlap/adjacency coalescing prevents duplicate
file-byte amplification. A zero-length file with a nonzero suffix range is
satisfiable; our policy ignores that range and returns the empty representation.
Unknown/invalid range syntax is also ignored; excessive or wholly unsatisfiable
range sets yield a rejection result. These are explicit server policy choices.

Boundary/media validation and exact multipart lengths keep response framing
independent of file reads. Strong validators can authorize If-Range; callers must
not label metadata-only validators strong without evidence. Last-Modified dates
are not implicitly strong. The Lantern server uses conservative weak metadata
tags to avoid a whole-file hash on a large-file request.

Tests include precondition precedence, weak and strong validators, quoted commas,
obsolete dates and the 50-year rule, huge decimal offsets, empty representations,
range ordering/coalescing and multipart injection rejection. Generated cases compare
normalized range coverage with an independent per-byte oracle and check encoded
body lengths. The server repo separately verifies actual files, keep-alive framing,
TLS, atomic publication races, HEAD, 304, 412 and 416 responses.

## Fragmented line cost (2026-10-16)

[RFC 9112 section 2.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-2.2)
defines octet-oriented parsing. Our CRLF/size policy must also hold when transport
reads split any delimiter. The original implementation repeatedly concatenated
and searched the entire pending prefix, causing quadratic copying/scanning for
a long byte-at-a-time line. The replacement retains fragments, checks their
total before concatenation, and searches only newly received bytes plus the
previous-CR/new-LF boundary. Each pending byte is searched a bounded number of
times; the completed line is concatenated once and checked for bare CR/LF.

Existing complete buffer slices stay on a direct path. The number of retained
fragment nodes is bounded by pending bytes (empty receive means EOF); this adds
metadata per fragment, not an unbounded queue. Error/cancellation still poisons
the connection. Tests cover exact and overflowing line sizes, split delimiters,
bare newlines, bodies, following requests and generated irregular splits.
[Measured CPU/allocation observations](fragmentation.md) are scoped to this
parser experiment; resource deadlines/admission remain the server's job.

## Target validation without a byte list (2026-10-16)

[RFC 3986 section 2.1](https://www.rfc-editor.org/rfc/rfc3986.html#section-2.1)
defines percent encoding with two hexadecimal digits. Lantern's existing target
profile is retained; this change does not expand it or claim complete generic URI
conformance. The validator walks the original bytes by index, checks the end
before each access, and checks both percent bytes before advancing three places.
It never decodes escapes or rewrites the target. The previous list-based policy
is retained as a test oracle for acceptance and exact target preservation.

Single-byte suffix enumeration, valid/invalid/truncated escapes and 3000 generated
fragmented requests complement existing line-limit/body/pipeline tests. Those
long target tests now use a varied pattern to expose ordering mistakes.
[The unchanged benchmark helper](target-scan.md) measures the allocation removed
from long targets and records every alternating trial, with explicit scope limits.
