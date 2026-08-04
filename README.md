# ipcmail

A unified inter-process messaging library for Crystal. One `send`/`receive`
interface over four transports, selected by URI scheme:

| Scheme    | Class                   | Model                                                 |
|-----------|-------------------------|-------------------------------------------------------|
| `shm://`  | `IPCMail::SharedMemory` | 1:1 point-to-point over lock-free shared-memory rings |
| `bus://`  | `IPCMail::Bus`          | 1:N publish/subscribe with type filters               |
| `unix://` | `IPCMail::Socket`       | stream over a UNIX domain socket                      |
| `fifo://` | `IPCMail::Pipe`         | stream over a named FIFO, or an anonymous pair        |

Every endpoint is addressed by a URI. The scheme picks the transport; query
parameters configure it, so a fully-specified URI needs no keyword arguments.
All four transports share the `IPCMail::Mailbox` interface, so once an endpoint
is open the sending and receiving code is identical regardless of which
transport backs it.

> **Platform:** Linux / POSIX only. ipcmail relies on `shm_open`, `mkfifo`,
> UNIX domain sockets, and `SO_PEERCRED`, so it does not run on Windows.

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  ipcmail:
    github: shpeckman/ipcmail
```

Then run `shards install`.

## Quick start

```crystal
require "ipcmail"

# create allocates the endpoint; open attaches to an existing one.
producer = IPCMail.create("shm://jobs")
consumer = IPCMail.open("shm://jobs")

producer.send("hello")
message = consumer.receive          # => IPCMail::Message
puts message.text                   # "hello"

consumer.close
producer.close                      # the last endpoint to close unlinks the segment
```

The block form yields the endpoint and closes it on exit, even on a raise:

```crystal
IPCMail.create("shm://jobs") do |mailbox|
  mailbox.send("work")
end   # closed here
```

## The URI model

The scheme selects the transport and query parameters configure it:

```
shm://name        SharedMemory  (1:1 point-to-point)
bus://name        Bus           (1:N publish/subscribe)
unix://path       Socket        (UNIX domain socket stream)
fifo://path       Pipe          (named FIFO stream)
```

Every keyword argument has a query-parameter equivalent, so these two lines are
the same endpoint:

```crystal
IPCMail.create("shm://jobs?capacity=64&bsize=512&overflow=block")
IPCMail.create("shm://jobs", capacity: 64, block_size: 512, overflow: :block)
```

| Parameter      | Aliases        | Meaning                           | Default    |
|----------------|----------------|-----------------------------------|------------|
| `capacity`     | `msgs`         | ring capacity (min 2)             | 32         |
| `block_size`   | `bsize`        | bytes per block                   | 256        |
| `blocks`       | `bcount`       | number of blocks                  | 64         |
| `trace`        |                | trace ring capacity (0 disables)  | 0          |
| `subscribers`  | `subs`         | bus subscriber slots (max 16)     | 16         |
| `overflow`     |                | `fail` \| `block` \| `spill`      | `fail`     |
| `mode`         | `permissions`  | octal file mode (e.g. `mode=644`) | `0600`     |
| `framed`       | `stream`       | stream length-prefixing           | `framed=1` |
| `direction`    | `read`/`write` | fifo direction                    | required   |
| `authenticate` |                | unix peer-uid check               | `0`        |

## Choosing an endpoint

`IPCMail.create`, `.open`, and `.listen` each come in three forms.

**Generic** — returns an `IPCMail::Mailbox`, dispatching on the scheme:

```crystal
mailbox = IPCMail.open("shm://jobs")   # => Mailbox
```

**Typed** — pass the concrete class first. The return type narrows and the
scheme is asserted; a mismatch raises `IPCMail::SchemeError` with a corrective
message:

```crystal
shm  = IPCMail.open(IPCMail::SharedMemory, "shm://jobs")       # => SharedMemory
bus  = IPCMail.create(IPCMail::Bus, "bus://events?subs=8")     # => Bus
sock = IPCMail.open(IPCMail::Socket, "unix:///tmp/app.sock")   # => Socket
pipe = IPCMail.create(IPCMail::Pipe, "fifo:///tmp/log", direction: :write)
```

**Block** — either of the above with a block yields the endpoint and closes it
afterwards:

```crystal
IPCMail.create(IPCMail::SharedMemory, "shm://jobs") do |mailbox|
  mailbox.send("x")
end
```

## Sending

Every mailbox accepts three send forms:

```crystal
mailbox.send("text")                                        # String
mailbox.send(bytes, type: 7, priority: :high, timeout: 1.second)  # Bytes + metadata

mailbox.send(256) do |slice|   # zero-copy: write straight into the reserved block
  slice.copy_from("data".to_slice)
end
```

`send` raises `IPCMail::TimeoutError` on a miss. `send?` returns a `Bool`
instead and never raises on a timeout, a full mailbox, or a closed peer:

```crystal
mailbox.send?("maybe", timeout: 10.milliseconds)   # => Bool
```

## Receiving

```crystal
message = mailbox.receive               # => Message, raises TimeoutError on a miss
message = mailbox.receive(1.second)     # with a timeout
maybe   = mailbox.receive?(50.milliseconds)  # => Message?, nil on a miss
```

The block form of `receive` hands you a `View` — a borrowed window into the
underlying block, valid only for the duration of the block. It performs no copy;
call `view.copy` if you need to retain the data past the block:

```crystal
mailbox.receive do |view|          # view : IPCMail::View
  process(view.to_slice)
  retained = view.copy             # => Message
end
```

`each` drains the mailbox until a receive misses or the mailbox closes:

```crystal
mailbox.each(timeout: 100.milliseconds) do |message|
  handle(message)
end
```

## Priority

Messages carry a `Normal` or `High` priority. High-priority messages are
dequeued first, regardless of send order:

```crystal
producer.send("low",  priority: :normal)
producer.send("high", priority: :high)

consumer.receive.text   # "high"
consumer.receive.text   # "low"
```

## Overflow policies

`overflow` governs what happens when every block is in use at send time:

- **`:fail`** — raise `FullError` immediately (no timeout), or `TimeoutError`
  once a timeout elapses.
- **`:block`** — wait for a free block until the timeout elapses.
- **`:spill`** — *(shm only)* overflow is written to a side FIFO and drained
  transparently by a normal `receive` loop, so nothing is lost or reordered.

```crystal
IPCMail.create(IPCMail::SharedMemory, "shm://q", blocks: 4, overflow: :block)
IPCMail.create("shm://q?blocks=4&overflow=block")   # URI form
```

Spill is invisible to the receiver — a plain `receive` loop sees spilled and
in-ring messages together, in order:

```crystal
a = IPCMail.create(IPCMail::SharedMemory, "shm://spill", blocks: 1, overflow: :spill)
b = IPCMail.open(IPCMail::SharedMemory, "shm://spill", overflow: :spill)

a.send("first")    # fills the single block
a.send("second")   # spills to the side FIFO
a.send("third")    # spills too

3.times { puts b.receive.text }   # first, second, third
```

## Publish / subscribe

A `bus://` endpoint fans one message out to many subscribers. Each subscriber
claims a slot and may filter by message type (up to 8 filters; no filters means
all types):

```crystal
bus = IPCMail.create(IPCMail::Bus, "bus://events?subs=16")

s1 = IPCMail.open(IPCMail::Bus, "bus://events"); s1.subscribe
s2 = IPCMail.open(IPCMail::Bus, "bus://events"); s2.subscribe(1, 2, 3)

reached = bus.publish("update", type: 1)   # => Int32, subscribers matched

s1.receive { |view| puts view.text }
s2.receive { |view| puts view.text }
```

`publish` mirrors `send`'s three forms (String, Bytes, and the zero-copy block
form) and returns the number of subscribers it delivered to.

## UNIX sockets

`listen` returns an `IPCMail::Socket::Server`. `authenticate=1` rejects peers
whose uid differs from the current user:

```crystal
server = IPCMail.listen("unix:///tmp/app.sock?authenticate=1")

server.each(timeout: 5.seconds) do |conn|   # conn : IPCMail::Socket
  request = conn.receive(1.second)
  conn.send("ack", type: request.type)
  conn.close
end

server.close   # deletes the socket file
```

The client side retries until the server is up or the timeout elapses:

```crystal
client = IPCMail.open(IPCMail::Socket, "unix:///tmp/app.sock", timeout: 5.seconds)
client.send("ping", type: 1)
reply = client.receive(1.second)
```

A connected socket can report the peer's credentials:

```crystal
creds = conn.peer_credentials   # => IPCMail::Credentials (pid, uid, gid)
```

By default streams are **framed** — each message is length-prefixed, so
`receive` returns whole messages. Pass `stream=1` (or `framed=0`) for a raw byte
stream, where `receive` returns whatever bytes are available one chunk at a time:

```crystal
IPCMail.listen("unix:///tmp/raw.sock?stream=1")
```

## Pipes

An anonymous pair of connected pipes, backed by OS pipes with no filesystem name:

```crystal
left, right = IPCMail::Pipe.pair(framed: true)

spawn do
  right.send("data")
  right.close
end

message = left.receive(1.second)
left.close
```

A named FIFO is one-directional; give it a direction. Opening the reader blocks
until a writer appears, up to the timeout:

```crystal
writer = IPCMail.create(IPCMail::Pipe, "fifo:///tmp/log.fifo", direction: :write)
writer.send("line")
writer.close

reader = IPCMail.open(IPCMail::Pipe, "fifo:///tmp/log.fifo", direction: :read, timeout: 5.seconds)
line = reader.receive(1.second)
reader.unlink   # remove the FIFO file
reader.close
```

The direction may also be given in the URI: `?direction=read`, or the shorthand
flags `?read=1` / `?write=1`.

## Introspection and monitoring

Each shared-memory or bus mailbox reports its own queue depths:

```crystal
mailbox.pending      # messages waiting for THIS side to receive
mailbox.queued       # messages THIS side has queued for the peer (shm)
mailbox.capacity
mailbox.block_size
```

`IPCMail.monitor` attaches to an `shm://` or `bus://` segment read-only, without
joining traffic, and reports live statistics:

```crystal
mon = IPCMail.monitor("bus://events")
stats = mon.stats            # => IPCMail::Monitor::Stats
stats.usage                  # Float64, blocks in use as a percentage
mon.close
```

A segment created with `trace > 0` records every send and receive. `trace`
returns the records since the previous call:

```crystal
seg = IPCMail.create(IPCMail::SharedMemory, "shm://traced", trace: 64)

seg.trace(64).each do |record|   # record : IPCMail::TraceRecord
  puts record   # "#12 TX lane=A type=0 size=1 priority=Normal"
end
```

## Bare shared memory

`IPCMail::Buffer` is a plain mmap'd region for when you want raw shared bytes
rather than a mailbox. Names must be a single leading slash followed by a name:

```crystal
buf = IPCMail::Buffer.create(4096, "/myapp-scratch")
buf.to_slice[0] = 42_u8

ro = IPCMail::Buffer.open("/myapp-scratch", read_only: true, timeout: 5.seconds)
ro.to_slice   # read-only Bytes
ro.close

buf.close   # a creator close unlinks by default; close(unlink: false) keeps it
```

Omit the name for a generated unique one, and use the block form to auto-close:

```crystal
IPCMail::Buffer.create(1 << 20) do |buf|
  # ... use it ...
end   # closed and unlinked here
```

## Reusing settings

`IPCMail::Config` bundles the segment settings so a profile can be defined once
and reused. Note that the class-level `SharedMemory.create` / `Bus.create` take
a bare **name**, not a URI — scheme dispatch lives only in the top-level
`IPCMail.create` / `.open`:

```crystal
config = IPCMail::Config.new(
  capacity: 64, block_size: 512, blocks: 128,
  trace: 256, subscribers: 8, overflow: :block, mode: 0o600,
)

a   = IPCMail::SharedMemory.create("profiled", config)
bus = IPCMail::Bus.create("profiled-bus", config)
```

## Error handling

Every exception inherits `IPCMail::Error < Exception`:

```crystal
begin
  mailbox.send("x", timeout: 100.milliseconds)
  message = mailbox.receive(1.second)
rescue IPCMail::TimeoutError    # send/receive/accept exceeded the timeout
rescue IPCMail::FullError       # :fail overflow, no timeout, no free block
rescue IPCMail::ClosedError     # endpoint or peer is closed
rescue IPCMail::MessageTooLarge # payload exceeds block_size or the frame limit
rescue IPCMail::SchemeError     # wrong scheme for the verb / typed class
rescue IPCMail::CorruptSegment  # segment mismatch on attach
rescue IPCMail::PermissionDenied # authenticate=1 and the peer uid did not match
rescue IPCMail::SystemError     # a syscall failed; carries .errno : Errno
end
```

---

# API reference

Public API only. Internal machinery (`Segment`, `Layout`, `Signal`, `Framing`,
`LibIPC`, `Deadline`) is omitted.

## `IPCMail`

Top-level factory methods. Each `create`/`open`/`listen` has a generic form
(returns the interface type), a typed form (pass the class first, get the
concrete type back with the scheme asserted), and a block form that closes the
endpoint on exit.

| Method                                                                                                                        | Description                                                          |
|-------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------|
| `IPCMail.create(uri : String, **options) : Mailbox`                                                                           | Allocate the endpoint named by `uri`; dispatches on the scheme.      |
| `IPCMail.create(uri : String, **options, &)`                                                                                  | Block form; yields the mailbox and closes it afterwards.             |
| `IPCMail.create(kind : Class, uri : String, **options)`                                                                       | Typed form for `SharedMemory`, `Bus`, or `Pipe`; asserts the scheme. |
| `IPCMail.create(kind : Class, uri : String, **options, &)`                                                                    | Typed block form.                                                    |
| `IPCMail.open(uri : String, **options) : Mailbox`                                                                             | Attach to an existing endpoint; dispatches on the scheme.            |
| `IPCMail.open(uri : String, **options, &)`                                                                                    | Block form.                                                          |
| `IPCMail.open(kind : Class, uri : String, **options)`                                                                         | Typed form for `SharedMemory`, `Bus`, `Socket`, or `Pipe`.           |
| `IPCMail.open(kind : Class, uri : String, **options, &)`                                                                      | Typed block form.                                                    |
| `IPCMail.listen(uri : String, *, framed = nil, authenticate = nil, backlog = Socket::SOMAXCONN, mode = nil) : Socket::Server` | Bind a `unix://` server socket.                                      |
| `IPCMail.listen(uri : String, **options, &)`                                                                                  | Block form; closes the server afterwards.                            |
| `IPCMail.listen(kind : Socket::Server.class, uri : String, **options)`                                                        | Typed form.                                                          |
| `IPCMail.listen(kind : Socket::Server.class, uri : String, **options, &)`                                                     | Typed block form.                                                    |
| `IPCMail.monitor(uri : String, timeout = 5.seconds) : Monitor`                                                                | Attach read-only to an `shm://` or `bus://` segment for inspection.  |
| `IPCMail::VERSION`                                                                                                            | The shard version string.                                            |

Common options across `create`/`open`: `capacity`, `block_size`, `blocks`,
`trace`, `subscribers`, `overflow`, `mode`, `framed`, `direction`, `timeout`.

## `IPCMail::Mailbox`

Abstract base shared by all four transports.

| Method                                                                                    | Description                                                    |
|-------------------------------------------------------------------------------------------|----------------------------------------------------------------|
| `send(payload : Bytes \| String, *, type = 0, priority = :normal, timeout = nil) : Nil`   | Send a payload; raises `TimeoutError` on a miss.               |
| `send(size : Int, *, type = 0, priority = :normal, timeout = nil, & : Bytes ->) : Nil`    | Zero-copy send; the block writes into the reserved slice.      |
| `send?(payload : Bytes \| String, *, type = 0, priority = :normal, timeout = nil) : Bool` | Send without raising on timeout, full mailbox, or closed peer. |
| `receive(timeout = nil) : Message`                                                        | Receive a message; raises `TimeoutError` on a miss.            |
| `receive?(timeout = nil) : Message?`                                                      | Receive, returning `nil` on a miss.                            |
| `receive(timeout = nil, & : View ->)`                                                     | Borrowed receive; yields a `View` valid only inside the block. |
| `each(timeout = nil, & : Message ->) : Nil`                                               | Yield messages until a receive misses or the mailbox closes.   |
| `close : Nil`                                                                             | Close the endpoint.                                            |
| `closed? : Bool`                                                                          | Whether the endpoint is closed.                                |

## `IPCMail::SharedMemory < Mailbox`

1:1 point-to-point, full-duplex, over lock-free shared-memory rings.

| Method                                                                                                                                       | Description                                    |
|----------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------|
| `SharedMemory.create(name : String, capacity = 32, block_size = 256, blocks = 64, trace = 0, overflow = :fail, mode = 0o600) : SharedMemory` | Create a segment by name.                      |
| `SharedMemory.create(name : String, config : Config) : SharedMemory`                                                                         | Create using a `Config`.                       |
| `SharedMemory.open(name : String, timeout = 5.seconds, overflow = :fail, mode = 0o600) : SharedMemory`                                       | Attach to an existing segment.                 |
| `block_size : UInt32`                                                                                                                        | Bytes per block.                               |
| `capacity : UInt32`                                                                                                                          | Ring capacity.                                 |
| `pending : UInt32`                                                                                                                           | Messages waiting for this side to receive.     |
| `queued : UInt32`                                                                                                                            | Messages this side has queued for the peer.    |
| `overflow : Overflow`                                                                                                                        | The active overflow policy.                    |
| `overflow_receive?(timeout = nil) : Message?`                                                                                                | Drain only the spill FIFO, bypassing the ring. |
| `trace(limit = 64) : Array(TraceRecord)`                                                                                                     | Trace records since the previous call.         |
| `closed? : Bool`                                                                                                                             | Whether the mailbox is closed.                 |

## `IPCMail::Bus < Mailbox`

1:N publish/subscribe. Publishers `publish`; subscribers `subscribe` then
`receive`.

| Method                                                                                                                                       | Description                                         |
|----------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| `Bus.create(name : String, capacity = 32, block_size = 256, blocks = 64, trace = 0, subscribers = 16, overflow = :fail, mode = 0o600) : Bus` | Create a bus segment by name.                       |
| `Bus.create(name : String, config : Config) : Bus`                                                                                           | Create using a `Config`.                            |
| `Bus.open(name : String, timeout = 5.seconds, overflow = :fail, mode = 0o600) : Bus`                                                         | Attach to an existing bus.                          |
| `subscribe : Nil`                                                                                                                            | Subscribe to all message types.                     |
| `subscribe(*types : Int) : Nil`                                                                                                              | Subscribe to specific types (max 8).                |
| `subscribe(types : Enumerable(Int)) : Nil`                                                                                                   | Subscribe with an enumerable of types.              |
| `unsubscribe : Nil`                                                                                                                          | Release the subscriber slot (also done on close).   |
| `subscribed? : Bool`                                                                                                                         | Whether this endpoint holds a slot.                 |
| `slot : UInt32?`                                                                                                                             | The assigned slot, or `nil`.                        |
| `publish(payload : Bytes \| String, *, type = 0, priority = :normal, timeout = nil) : Int32`                                                 | Publish; returns the number of subscribers reached. |
| `publish(size : Int, *, type = 0, priority = :normal, timeout = nil, & : Bytes ->) : Int32`                                                  | Zero-copy publish.                                  |
| `receive(timeout = nil, & : View ->)`                                                                                                        | Borrowed receive for the subscribed slot.           |
| `block_size : UInt32`                                                                                                                        | Bytes per block.                                    |
| `subscribers : UInt32`                                                                                                                       | Live subscriber count on the segment.               |
| `pending : UInt32`                                                                                                                           | Queued messages for this subscriber.                |
| `overflow : Overflow`                                                                                                                        | The active overflow policy (`spill` is rejected).   |
| `trace(limit = 64) : Array(TraceRecord)`                                                                                                     | Trace records since the previous call.              |
| `closed? : Bool`                                                                                                                             | Whether the bus is closed.                          |

## `IPCMail::Socket < Mailbox`

Stream over a UNIX domain socket. Connect with `IPCMail.open`; accept with a
`Socket::Server`.

| Method                                                                       | Description                                                |
|------------------------------------------------------------------------------|------------------------------------------------------------|
| `Socket.connect(path : String, framed = true, timeout = 5.seconds) : Socket` | Connect to a listening socket, retrying until the timeout. |
| `path : String`                                                              | The socket path.                                           |
| `peer_credentials : Credentials`                                             | The connected peer's pid, uid, and gid.                    |
| `framed? : Bool`                                                             | Whether messages are length-framed.                        |
| `readable? : Bool`                                                           | Whether the stream can be read.                            |
| `writable? : Bool`                                                           | Whether the stream can be written.                         |
| `fd : Int32`                                                                 | The underlying file descriptor.                            |
| `closed? : Bool`                                                             | Whether the socket is closed.                              |

### `IPCMail::Socket::Server`

| Method                                                                                                                          | Description                                           |
|---------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------|
| `Socket::Server.listen(path : String, framed = true, authenticate = false, backlog = Socket::SOMAXCONN, mode = 0o600) : Server` | Bind and listen on a socket path.                     |
| `accept(timeout = nil) : Socket`                                                                                                | Accept a connection; raises `TimeoutError` on a miss. |
| `accept?(timeout = nil) : Socket?`                                                                                              | Accept, returning `nil` on a miss.                    |
| `each(timeout = nil, & : Socket ->) : Nil`                                                                                      | Accept connections until closed or a miss.            |
| `path : String`                                                                                                                 | The socket path.                                      |
| `framed? : Bool`                                                                                                                | Whether accepted connections are framed.              |
| `close : Nil`                                                                                                                   | Close the server and delete the socket file.          |
| `closed? : Bool`                                                                                                                | Whether the server is closed.                         |

## `IPCMail::Pipe < Mailbox`

Stream over a named FIFO, or an anonymous connected pair.

| Method                                                                                                     | Description                                                 |
|------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------|
| `Pipe.pair(framed = true) : Tuple(Pipe, Pipe)`                                                             | Two connected pipes backed by OS pipes, no filesystem name. |
| `Pipe.fifo(path : String, direction : Direction, framed = true, timeout = 5.seconds, mode = 0o600) : Pipe` | Open one direction of a named FIFO.                         |
| `path : String?`                                                                                           | The FIFO path, or `nil` for an anonymous pair.              |
| `unlink : Nil`                                                                                             | Remove the FIFO file, if named.                             |
| `framed? : Bool`                                                                                           | Whether messages are length-framed.                         |
| `readable? : Bool`                                                                                         | Whether the pipe can be read.                               |
| `writable? : Bool`                                                                                         | Whether the pipe can be written.                            |
| `fd : Int32`                                                                                               | The underlying file descriptor.                             |
| `closed? : Bool`                                                                                           | Whether the pipe is closed.                                 |

`IPCMail::Pipe::Direction` is an enum of `Read` and `Write`.

## `IPCMail::Monitor`

Read-only, non-participating attachment to an `shm://` or `bus://` segment.

| Method                                                      | Description                            |
|-------------------------------------------------------------|----------------------------------------|
| `Monitor.open(uri : String, timeout = 5.seconds) : Monitor` | Attach to a segment for inspection.    |
| `stats : Stats`                                             | Snapshot of live segment statistics.   |
| `trace(limit = 64) : Array(TraceRecord)`                    | Trace records since the previous call. |
| `close : Nil`                                               | Detach from the segment.               |
| `closed? : Bool`                                            | Whether the monitor is closed.         |

### `IPCMail::Monitor::Stats`

A read-only snapshot with getters `name : String`, `kind : Kind`,
`capacity : UInt32`, `block_size : UInt32`, `block_count : UInt32`,
`blocks_in_use : UInt32`, `subscribers : UInt32`, `max_subscribers : UInt32`,
`trace_capacity : UInt32`, `lanes : Array(UInt32)` (depth of each of the four
lanes), and `rings : Array(Tuple(UInt32, UInt32, UInt32))` (`{slot, normal, high}`
per subscriber). `usage : Float64` reports `blocks_in_use` as a percentage.

## `IPCMail::Buffer`

A bare shared-memory region — raw bytes, not a mailbox. Names must be a single
leading slash followed by a name.

| Method                                                                   | Description                                             |
|--------------------------------------------------------------------------|---------------------------------------------------------|
| `Buffer.create(size : Int, name : String? = nil, mode = 0o600) : Buffer` | Create a region; a `nil` name generates a unique one.   |
| `Buffer.create(size : Int, name : String? = nil, mode = 0o600, &)`       | Block form; closes and unlinks afterwards.              |
| `Buffer.open(name : String, read_only = false, timeout = nil) : Buffer`  | Attach to an existing region.                           |
| `Buffer.open(name : String, read_only = false, timeout = nil, &)`        | Block form.                                             |
| `Buffer.unlink(name : String) : Bool`                                    | Remove a named region; `false` if it did not exist.     |
| `Buffer.generate : String`                                               | A unique region name (`/ipcmail-<pid>-<hex>`).          |
| `to_slice : Bytes`                                                       | The region as a `Bytes` slice (read-only if opened so). |
| `to_unsafe : Pointer(UInt8)`                                             | The base pointer, for regions larger than `Int32::MAX`. |
| `name : String`                                                          | The region name.                                        |
| `size : Int64`                                                           | The region size in bytes.                               |
| `creator? : Bool`                                                        | Whether this handle created the region.                 |
| `read_only? : Bool`                                                      | Whether the mapping is read-only.                       |
| `close(unlink : Bool? = nil) : Nil`                                      | Unmap; a creator close unlinks by default.              |
| `unlink : Bool`                                                          | Unlink the region.                                      |
| `closed? : Bool`                                                         | Whether the buffer is closed.                           |

## Values

### `IPCMail::Config`

Bundles segment settings for reuse. Constructor:
`Config.new(capacity = 32, block_size = 256, blocks = 64, trace = 0, subscribers = 16, overflow = :fail, mode = 0o600)`,
validated on construction. Getters: `capacity`, `block_size`, `blocks`, `trace`,
`subscribers`, `overflow`, `mode`.

### `IPCMail::Message`

An owned, received message. Getters `payload : Bytes`, `type : UInt32`,
`priority : Priority`. Also `size : Int32`, `text : String` (payload as UTF-8),
and `to_slice : Bytes`.

### `IPCMail::View`

A borrowed window into a block, valid only inside a `receive` block. Getters
`payload : Bytes`, `type : UInt32`, `priority : Priority`. Also `size : Int32`,
`text : String`, `to_slice : Bytes`, and `copy : Message` to retain the data.

### `IPCMail::TraceRecord`

A single trace entry. Getters `at : Time`, `sequence : UInt64`, `type : UInt32`,
`size : UInt32`, `priority : Priority`, `lane : Lane`, `event : Event`.

### `IPCMail::Credentials`

A connected peer's identity. Getters `pid : Int32`, `uid : UInt32`,
`gid : UInt32`.

## Enums

| Enum                       | Members                  |
|----------------------------|--------------------------|
| `IPCMail::Priority`        | `Normal`, `High`         |
| `IPCMail::Overflow`        | `Fail`, `Block`, `Spill` |
| `IPCMail::Kind`            | `PointToPoint`, `Bus`    |
| `IPCMail::Lane`            | `A`, `B`                 |
| `IPCMail::Event`           | `Send`, `Receive`        |
| `IPCMail::Pipe::Direction` | `Read`, `Write`          |

## Exceptions

All inherit `IPCMail::Error < Exception`.

| Exception                   | Raised when                                                                        |
|-----------------------------|------------------------------------------------------------------------------------|
| `IPCMail::TimeoutError`     | A `send`/`receive`/`accept` exceeded its timeout.                                  |
| `IPCMail::FullError`        | `:fail` overflow with no timeout and no free block.                                |
| `IPCMail::ClosedError`      | The endpoint or its peer is closed (streams also raise this mid-frame on a stall). |
| `IPCMail::MessageTooLarge`  | A payload exceeds `block_size` (shm/bus) or the frame limit (stream).              |
| `IPCMail::SchemeError`      | The wrong scheme was used for a verb or typed class.                               |
| `IPCMail::CorruptSegment`   | A segment's magic, version, kind, or layout mismatched on attach.                  |
| `IPCMail::PermissionDenied` | `authenticate=1` and the peer uid did not match.                                   |
| `IPCMail::SystemError`      | A syscall failed; carries `errno : Errno`.                                         |
| `IPCMail::Unsupported`      | An operation is not supported by the transport.                                    |

## License

MIT.