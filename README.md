# ipcmail

Fast, crash-resilient inter-process messaging for Crystal.

`ipcmail` gives multiple processes on the same host a small set of mailbox
primitives that share one URI-addressed API:

- **`shm://`** — point-to-point shared-memory mailbox, full-duplex, zero-copy on the receive path.
- **`bus://`** — shared-memory broadcast bus with per-subscriber rings and type filtering.
- **`unix://`** — Unix domain socket transport with optional length framing and peer authentication.
- **`fifo://`** — named FIFO pipe transport for one-way streaming.
- **`pty://`** — pseudoterminal transport for driving terminal-oriented child processes.

The shared-memory transports are lock-protected with a robust, self-healing
mutex: if a process dies while holding the lock or owning message blocks, the
next process to touch the segment steals the lock, repairs the ring, and
reclaims the dead owner's blocks.

Requires Crystal `>= 1.21.0`. Primary target is Linux; the Unix-socket
transport also runs on macOS/BSD (peer credentials fall back to `getpeereid`,
which reports uid/gid but not pid). The pseudoterminal transport is POSIX-wide;
it resolves the slave device with `ptsname_r` on Linux and `ptsname`
elsewhere.

## Installation

Add it to your `shard.yml`:

```yaml
dependencies:
  ipcmail:
    github: shpeckman/ipcmail
```

Then run `shards install` and require it:

```crystal
require "ipcmail"
```

## Quick start

Two endpoints on one shared-memory segment, exchanging messages:

```crystal
require "ipcmail"

server = IPCMail.create("shm://example?msgs=16&bsize=256")

spawn do
  worker = IPCMail.open("shm://example")
  message = worker.receive(timeout: 5.seconds)
  worker.send(message.text.upcase)
  worker.close
end

server.send("hello")
puts server.receive(timeout: 5.seconds).text # => "HELLO"

server.close
IPCMail.unlink("shm://example")
```

Runnable programs for every transport live in [`examples/`](examples):

```
crystal run examples/shared_memory.cr
crystal run examples/bus.cr
crystal run examples/socket.cr
crystal run examples/pipe.cr
crystal run examples/pty.cr
crystal run examples/large_payload.cr
crystal run examples/monitor.cr
```

## Endpoint URIs

Every endpoint is named by a URI. The scheme selects the transport, the
host/path is the endpoint name, and query parameters tune it.

| Scheme    | Transport                 | Created with     | Attached with  |
|-----------|---------------------------|------------------|----------------|
| `shm://`  | point-to-point shared mem | `IPCMail.create` | `IPCMail.open` |
| `bus://`  | broadcast bus             | `IPCMail.create` | `IPCMail.open` |
| `unix://` | Unix domain socket        | `IPCMail.listen` | `IPCMail.open` |
| `fifo://` | named FIFO pipe           | `IPCMail.create` | `IPCMail.open` |
| `pty://`  | pseudoterminal            | `IPCMail.create` | `IPCMail.open` |

Shared-memory names map directly to POSIX `shm_open` objects, so a leading
slash is normalized in for you (`shm://example` targets `/example`). Unix and
FIFO targets are filesystem paths (`unix:///tmp/app.sock`).

`pty://` is the one scheme with no name of its own: the kernel allocates the
device. Create it with an empty target (`pty://`) and attach to the slave it
reports by path (`pty:///dev/pts/7`).

### Query parameters

Parameters set on the URI are equivalent to the keyword arguments on the
factory methods; explicit keyword arguments win over the URI.

| Parameter             | Applies to            | Meaning                                         | Default |
|-----------------------|-----------------------|-------------------------------------------------|---------|
| `capacity`, `msgs`    | `shm`, `bus`          | ring slots per lane (must be ≥ 2)               | `32`    |
| `block_size`, `bsize` | `shm`, `bus`          | max bytes per message block                     | `256`   |
| `blocks`, `bcount`    | `shm`, `bus`          | number of shared payload blocks                 | `64`    |
| `subscribers`, `subs` | `bus`                 | max concurrent subscribers (1–16)               | `16`    |
| `trace`               | `shm`, `bus`          | ring size for the trace buffer (0 disables)     | `0`     |
| `overflow`            | `shm`, `bus`          | `fail`, `block`, or `spill`                     | `fail`  |
| `mode`, `permissions` | all                   | octal file mode for created objects             | `0600`  |
| `direction`           | `fifo`                | `read` or `write`                               | —       |
| `framed`              | `unix`, `fifo`, `pty` | length-prefix messages                          | `true`* |
| `stream`              | `unix`, `fifo`, `pty` | inverse of `framed` (`?stream=true` ⇒ unframed) | —       |
| `authenticate`        | `unix`                | reject peers not owned by the current user      | `false` |
| `rows`                | `pty`                 | initial terminal row count                      | —       |
| `columns`, `cols`     | `pty`                 | initial terminal column count                   | —       |
| `raw`                 | `pty`                 | put the line discipline in raw mode             | `true`  |

\* `framed` defaults to `false` on `pty://`, which carries a terminal byte
stream rather than discrete messages.

Example: `bus://events?subs=4&bsize=1024&trace=64&overflow=block`

## Overflow policies

When every payload block is in use, the `overflow` policy decides what a
producer does:

- **`:fail`** — raise `FullError` immediately (or `TimeoutError` when a
  timeout was given). The default.
- **`:block`** — wait for a block to free up, bounded by the send timeout.
- **`:spill`** — (`shm` only) overflow messages are written to a side FIFO and
  transparently drained back in order on receive. Preserves FIFO ordering
  across the ring/spill boundary. A `bus` cannot spill.

## Usage

### Point-to-point (`shm://`)

Full-duplex between exactly two endpoints. The creator and the opener each get
their own transmit/receive lanes; a third live attach is rejected.

```crystal
a = IPCMail.create("shm://chat?msgs=32&bsize=512")
b = IPCMail.open("shm://chat")

a.send("to b", type: 1, priority: :high)
b.send("to a")

b.receive.text          # => "to b"
a.receive.text          # => "to a"

a.pending               # messages waiting for a to receive
a.queued                # messages a has sent but b hasn't taken

a.close
b.close
IPCMail.unlink("shm://chat")
```

Zero-copy receive borrows the block for the duration of the block; the view is
only valid inside it:

```crystal
b.receive { |view| process(view.to_slice) } # no copy
```

### Broadcast bus (`bus://`)

Every published message is fanned out to all matching subscribers, each with
an independent ring. Subscribers may filter by message type (up to 8 types; an
empty filter set matches everything).

```crystal
publisher = IPCMail.create(IPCMail::Bus, "bus://events?subs=8")

spawn do
  sub = IPCMail.open(IPCMail::Bus, "bus://events")
  sub.subscribe(7)                    # only type 7
  sub.receive { |view| puts view.text }
  sub.close
end

sleep 100.milliseconds                # let subscribers register
delivered = publisher.publish("payload", type: 7)  # returns match count
```

`publish` returns the number of subscribers the message was delivered to.
Subscribers that died holding a full ring are pruned automatically so
publishers never hang on a dead peer.

### Unix sockets (`unix://`)

A server listens; clients connect. Messages are length-framed by default so
message boundaries are preserved; pass `framed: false` (or `?stream=true`) for
a raw byte stream.

```crystal
server = IPCMail.listen("unix:///tmp/app.sock", authenticate: true)

spawn do
  client = IPCMail.open(IPCMail::Socket, "unix:///tmp/app.sock")
  client.send("ping")
  puts client.receive(timeout: 5.seconds).text
  client.close
end

conn = server.accept(timeout: 5.seconds)
creds = conn.peer_credentials       # uid / gid / pid (pid nil on macOS/BSD)
conn.send("pong")
conn.close
server.close
```

With `authenticate: true`, a connection whose peer uid differs from the
server's is closed and raises `PermissionDenied`.

### Named pipes (`fifo://`)

One-way streaming through a FIFO. The reader and writer name a direction.

```crystal
spawn do
  reader = IPCMail.open("fifo:///tmp/app.fifo?direction=read")
  puts reader.receive(timeout: 5.seconds).text
  reader.close
end

writer = IPCMail.create("fifo:///tmp/app.fifo?direction=write")
writer.send("data")
writer.close
```

`IPCMail::Pipe.pair` also returns an in-process reader/writer pair backed by an
anonymous pipe, useful for tests and parent/child hand-offs.

### Pseudoterminals (`pty://`)

A pty is a bidirectional endpoint for programs that expect a terminal rather
than a pipe — line editors, shells, and anything that changes behaviour when
`isatty` is false. Creating one allocates the device; the master is returned to
you and the child is attached to the slave.

```crystal
master = IPCMail.create(IPCMail::Pty, "pty://?rows=24&cols=80")

slave = File.open(master.slave_path, "r+")
child = Process.new("/bin/sh", ["-c", "printf 'ready\\n'"],
  input: slave, output: slave, error: slave)
child.wait

puts master.receive(timeout: 1.second).text   # => "ready\n"

master.resize(rows: 40, columns: 132)

slave.close
master.close
```

Unlike the other stream transports, a pty defaults to **unframed** and to
**raw** mode. Both defaults exist for the same reason: a cooked line discipline
rewrites the byte stream (`ONLCR` turns `\n` into `\r\n`), which corrupts binary
payloads and framing headers alike. Raw mode makes the transport byte
transparent; framing on top of it is opt-in with `framed: true`.

Terminal geometry is part of the endpoint:

```crystal
master.winsize                       # => 24x80
master.winsize.rows                  # => 24_u16
master.resize(columns: 120)          # leaves the other dimensions alone
master.winsize = IPCMail::Pty::Winsize.new(40, 132, 640, 480)
```

Both ends see the same geometry and the same line discipline, so `raw!` and
`resize` may be called from either.

Closing the last slave descriptor is a **hangup**, not an end-of-file: the
master's next read fails with `EIO`, which surfaces as `ClosedError` (and is
absorbed by `each`). Output already buffered stays readable, but the portable
pattern is to keep a slave descriptor open in the parent for as long as you
intend to read — as the example above does.

`IPCMail::Pty.pair` returns a connected master/slave pair in one call, useful
for tests and for handing the slave to a child directly:

```crystal
master, slave = IPCMail::Pty.pair(rows: 24, columns: 80)
master.send("hello")
slave.receive(timeout: 1.second).text   # => "hello"
```

### Large / out-of-band payloads

Payloads bigger than the block size are staged in a shared buffer and handed
over by reference, over any transport:

```crystal
producer.send_large(one_megabyte_of_bytes)     # any Mailbox
message = consumer.receive_large(timeout: 5.seconds)
message.size                                     # full payload size
```

The receiver copies the payload out and unlinks the backing buffer. Ordinary
messages pass through `receive_large` unchanged, so a consumer can call it
uniformly.

### Timeouts and blocking

Every `send` / `receive` accepts a `timeout : Time::Span?`. `nil` means block
indefinitely (subject to the overflow policy). The `?`-suffixed variants return
`nil`/`false` instead of raising on timeout:

```crystal
mailbox.receive?(timeout: 1.second)      # Message | nil
mailbox.send?("best effort")             # Bool
mailbox.each(timeout: 100.milliseconds) { |m| handle(m) }  # until idle/closed
```

## Concurrency and execution contexts

ipcmail is built for Crystal 1.21's execution contexts. Idle waits are routed
through the event loop, so a fiber blocked in `receive` parks and yields its
scheduler thread rather than pinning it — this holds under
`Fiber::ExecutionContext::Concurrent`, `Parallel`, and `Isolated` alike. Fibers
in different contexts coordinate through shared memory, so two processes and two
parallel schedulers use the same delivery path.

The ownership rule is one mailbox per fiber. A mailbox owns transport state — a
`Bus` owns a single subscriber slot and one inbox signal; a `Stream` owns its
reader and writer — and that state is a single logical endpoint. Sharing one
handle across fibers races on the inbox and steals wakeups. To fan work across
cores, open one mailbox per fiber: each `Bus` subscriber claims its own slot,
each publisher owns its own handle. The cross-process segment lock is held only
for brief in-memory bookkeeping, so N independent handles scale cleanly across a
parallel context's schedulers.

```crystal
require "wait_group"

publisher  = IPCMail.create(IPCMail::Bus, "bus://work?subs=8&capacity=64")
consumers  = Fiber::ExecutionContext::Parallel.new("consumers", 4)
subscribed = WaitGroup.new(4)

4.times do
  consumers.spawn do
    sub = IPCMail.open(IPCMail::Bus, "bus://work")   # one Bus per fiber
    sub.subscribe
    subscribed.done
    sub.each { |m| handle(m) }
  ensure
    sub.close
  end
end

subscribed.wait
publisher.publish("go")
```

The one guarantee beyond the single-owner rule: the publish-side sender cache is
internally synchronized, so a stray cross-fiber publish degrades to a lost
wakeup rather than corrupting shared state. Everything else assumes single-fiber
ownership. See `examples/execution_context.cr` for a complete runnable version.

## Observability

Attach a read-only `Monitor` to any live `shm`/`bus` segment to inspect it
without participating:

```crystal
monitor = IPCMail.monitor("shm://chat")
stats   = monitor.stats

stats.blocks_in_use   # blocks currently held
stats.usage           # percent of blocks in use
stats.lanes           # depth of each of the 4 lanes
stats.attach_count    # live attachers
stats.generation      # increments on each recovery
stats.damaged?        # a crash is mid-recovery
stats.owner_alive?    # is the current lock owner still running

monitor.trace.each { |record| puts record }  # requires ?trace=N
monitor.close
```

Enabling `?trace=N` records the last `N` send/receive events per segment; both
`Monitor#trace` and `Mailbox#trace` return `TraceRecord`s and advance an
internal cursor so each call yields only what's new.

## Cleanup

Endpoints delete their OS artifacts when the last participant closes. After a
hard crash, force-clean a named endpoint (shared-memory object plus all its
signal FIFOs, or the socket/FIFO file):

```crystal
IPCMail.unlink("shm://chat")
IPCMail.unlink("unix:///tmp/app.sock")
```

A `pty://` endpoint owns no persistent artifact — the kernel reclaims the
device once both ends close — so `unlink` rejects it, as does `monitor`, which
only inspects shared-memory segments.

Every mailbox also has a finalizer, but explicit `close` (or the block forms
below) is strongly preferred.

## Block forms

`create`, `open`, and `listen` accept a block and close the endpoint on exit:

```crystal
IPCMail.create("shm://job") do |mailbox|
  mailbox.send("work")
end # closed here

IPCMail.listen("unix:///tmp/s.sock") do |server|
  server.each(timeout: 1.second) { |conn| serve(conn) }
end
```

## Public API

### Module `IPCMail`

| Method                                           | Description                                                                                 |
|--------------------------------------------------|---------------------------------------------------------------------------------------------|
| `create(uri, **opts)` / `create(uri, **opts, &)` | Create a `shm`/`bus`/`fifo`/`pty` endpoint.                                                 |
| `create(Kind, uri, **opts)`                      | Typed create; `Kind` is `SharedMemory`, `Bus`, `Pipe`, or `Pty`. Returns the concrete type. |
| `open(uri, **opts)` / `open(uri, **opts, &)`     | Attach to an existing endpoint.                                                             |
| `open(Kind, uri, **opts)`                        | Typed open; `Kind` is `SharedMemory`, `Bus`, `Socket`, `Pipe`, or `Pty`.                    |
| `listen(uri, **opts)` / `listen(uri, **opts, &)` | Create a `unix://` server (`Socket::Server`).                                               |
| `monitor(uri, timeout = 5.seconds)`              | Read-only `Monitor` for a live `shm`/`bus` segment.                                         |
| `unlink(uri) : Bool`                             | Force-remove an endpoint's OS artifacts.                                                    |

Common options: `capacity`, `block_size`, `blocks`, `subscribers`, `trace`,
`overflow`, `mode`, `framed`, `direction`, `raw`, `rows`, `columns`,
`authenticate`, `backlog`, `timeout`.

### `IPCMail::Mailbox` (base of every transport)

| Method                                                                    | Description                                                       |
|---------------------------------------------------------------------------|-------------------------------------------------------------------|
| `send(payload, *, type = 0, priority = :normal, timeout = nil)`           | Send `Bytes` or `String`.                                         |
| `send(size, *, ...) { \|slice\| ... }`                                    | Zero-copy send: fill the block in place.                          |
| `send?(payload, *, ...) : Bool`                                           | Best-effort send; `false` on timeout/full/closed/too-large.       |
| `send_large(payload, *, priority = :normal, timeout = nil, mode = 0o600)` | Out-of-band send of an oversized payload.                         |
| `receive(timeout = nil) : Message`                                        | Receive, raising `TimeoutError` on timeout.                       |
| `receive?(timeout = nil) : Message?`                                      | Receive, returning `nil` on timeout.                              |
| `receive(timeout = nil) { \|view\| ... }`                                 | Borrowed, zero-copy receive.                                      |
| `receive_large(timeout = nil) : Message`                                  | Resolve an out-of-band handle (or pass through a normal message). |
| `receive_large?(timeout = nil) : Message?`                                | As above, `nil` on timeout.                                       |
| `each(timeout = nil) { \|message\| ... }`                                 | Drain until idle or closed.                                       |
| `close` / `closed?`                                                       | Release the endpoint.                                             |

### `IPCMail::SharedMemory < Mailbox`

Adds `capacity`, `block_size`, `pending`, `queued`, `overflow`, `trace(limit = 64)`,
`overflow_receive?(timeout = nil)`, and `segment`.

### `IPCMail::Bus < Mailbox`

Adds `subscribe` / `subscribe(*types)` / `subscribe(Enumerable)`, `unsubscribe`,
`subscribed?`, `slot`, `subscribers`, `pending`, `capacity`, `block_size`,
`publish(...)` (returns delivery count), `trace(limit = 64)`, and `segment`. A
`Bus` is owned by a single fiber; open one per fiber to fan work across an
execution context (see [Concurrency and execution contexts](#concurrency-and-execution-contexts)).

### `IPCMail::Socket < Stream`

`Socket.connect(path, framed = true, timeout = 5.seconds)`, `peer_credentials`,
`readable?`, `writable?`, `fd`, plus the `Mailbox` send/receive methods.

`IPCMail::Socket::Server`: `listen(path, framed = true, authenticate = false,
backlog = SOMAXCONN, mode = 0o600)`, `accept(timeout)`, `accept?(timeout)`,
`each(timeout) { |socket| }`, `close`.

### `IPCMail::Pipe < Stream`

`Pipe.fifo(path, direction, framed = true, timeout = 5.seconds, mode = 0o600)`,
`Pipe.pair(framed = true)`, `path`, `unlink`.

### `IPCMail::Pty < Stream`

`Pty.open(framed = false, raw = true, rows = nil, columns = nil)` allocates a
device and returns the master; `Pty.attach(path, framed = false, raw = false,
rows = nil, columns = nil)` opens a slave by path; `Pty.pair(framed = false,
raw = true, rows = nil, columns = nil)` returns both. Adds `slave_path`,
`master?`, `slave?`, `winsize`, `winsize=`,
`resize(rows = nil, columns = nil, x_pixels = nil, y_pixels = nil)`, `raw!`,
and `raw?`, plus the `Mailbox` send/receive methods.

### `IPCMail::Buffer`

Raw named shared-memory region for manual out-of-band data.
`Buffer.create(size, name = nil, mode = 0o600)`,
`Buffer.open(name, read_only = false, timeout = nil)`, `Buffer.unlink(name)`,
plus `to_slice`, `to_unsafe`, `size`, `close(unlink = nil)`. Both `create` and
`open` have block forms.

### `IPCMail::Monitor`

`Monitor.open(uri, timeout = 5.seconds)`, `stats : Stats`, `trace(limit = 64)`,
`close`. `Stats` exposes `name`, `kind`, `capacity`, `block_size`,
`block_count`, `blocks_in_use`, `usage`, `subscribers`, `max_subscribers`,
`trace_capacity`, `lanes`, `rings`, `damaged?`, `owner_pid`, `owner_alive?`,
`attach_count`, `generation`.

### Value types

- **`Message`** — `payload : Bytes`, `type : UInt32`, `priority : Priority`, `size`, `text`, `to_slice`.
- **`View`** — borrowed, zero-copy counterpart of `Message`; `copy` promotes it to a `Message`.
- **`TraceRecord`** — `at`, `sequence`, `type`, `size`, `priority`, `lane`, `event`.
- **`Credentials`** — `pid : Int32?`, `uid : UInt32`, `gid : UInt32`.
- **`Pty::Winsize`** — terminal geometry; `rows`, `columns`, `x_pixels`, `y_pixels`, all `UInt16`.
- **`Config`** — the fully-resolved segment configuration.
- **`Handle`** — reference to an out-of-band buffer (used internally by `send_large`).

### Enums

`Priority` (`Normal`, `High`), `Overflow` (`Fail`, `Block`, `Spill`),
`Kind` (`PointToPoint`, `Bus`), `Pipe::Direction` (`Read`, `Write`).

### Errors

All inherit `IPCMail::Error`:

| Error              | Raised when                                              |
|--------------------|----------------------------------------------------------|
| `TimeoutError`     | an operation exceeds its deadline                        |
| `FullError`        | no free block under `:fail` with no timeout              |
| `ClosedError`      | the endpoint or peer is closed                           |
| `MessageTooLarge`  | a payload exceeds `block_size` (or a stream frame limit) |
| `SchemeError`      | a URI scheme doesn't match the requested operation       |
| `PermissionDenied` | peer authentication fails                                |
| `CorruptSegment`   | a segment's magic/version/layout is invalid              |
| `SystemError`      | an underlying syscall fails (carries `errno`)            |

## How it works

A shared-memory endpoint is a single `mmap`'d segment laid out as: a header
(magic, version, robust lock, recovery state, generation), lane ring buffers of
fixed-size descriptors, a pool of payload blocks, per-subscriber ring buffers
(bus only), and an optional trace ring. Messages up to `block_size` are copied
into a claimed block; the descriptor (block index, size, type) is pushed onto
the appropriate priority lane. High-priority messages are delivered ahead of
normal ones. Receivers pop a descriptor, read the block in place, and release
it back to the pool.

Cross-process mutual exclusion uses a POSIX semaphore that blocks (via
`sem_timedwait`) rather than spinning. The lock records its owning PID; if a
holder dies, a waiter detects the stall, verifies the owner is gone, steals the
lock, and runs recovery. Recovery bumps a generation counter, clamps any torn
ring indices, ignores out-of-range descriptors from a half-finished write, and
reclaims blocks and subscriber slots owned by dead processes. A lightweight
FIFO "signal" wakes blocked peers so waiting is event-driven rather than
polled.

## Development

A `Makefile` wraps the common tasks:

```
make check                 # compile-only check of the library
make spec                  # full suite, including multi-process crash-recovery tests
make examples              # build and run every example in examples/
make bench                 # run every benchmark in bench/ (--release)
make spec-ec               # execution-context spec under CRYSTAL_WORKERS
make examples-ec           # execution-context example under CRYSTAL_WORKERS
make bench-ec              # execution-context benchmark under CRYSTAL_WORKERS
make run-<name>            # run a single example, e.g. make run-bus
make bench-<name>          # run a single benchmark, e.g. make bench-shm
```

`spec-ec`, `examples-ec`, and `bench-ec` set `CRYSTAL_WORKERS` (default `4`,
override with `make bench-ec CRYSTAL_WORKERS=8`) so the parallel-context tests,
example, and benchmark exercise real multi-scheduler delivery. Plain
`crystal spec` / `crystal run` work too. Benchmarks always compile `--release`;
they report sustained one-way throughput (msg/s and MiB/s) and round-trip
latency percentiles (min/mean/p50/p90/p99/max) per transport, plus bus fan-out
and parallel-consumer scaling.

The spec suite spawns real child processes (via `spec/support/peer.cr`) to
SIGKILL a lock holder mid-critical-section and assert the segment recovers.
`spec/bus_execution_context_spec.cr` fans a bus across `Parallel` and
`Isolated` contexts to exercise per-fiber ownership under real parallelism.

> **Note:** this codebase uses manual column alignment. Do **not** run
> `crystal tool format` — it would rewrite the alignment throughout.

## License

MIT. See [LICENSE](LICENSE).