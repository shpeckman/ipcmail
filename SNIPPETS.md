SNIPPETS: ipcmail
=================

### the URI model

```cr
require "ipcmail"

# every endpoint is a URI; the scheme picks the transport:
#   shm://name    -> SharedMemory  (1:1 point-to-point, lock-free rings)
#   bus://name    -> Bus           (1:N publish/subscribe)
#   unix://path   -> Socket        (stream over a UNIX domain socket)
#   fifo://path   -> Pipe          (stream over a named FIFO, or an anonymous pair)
#
# query params configure the endpoint, so a fully-specified URI needs no kwargs:
#   capacity | msgs       ring capacity        (default 32, min 2)
#   block_size | bsize    bytes per block      (default 256)
#   blocks | bcount       number of blocks     (default 64)
#   trace                 trace ring capacity  (default 0 = disabled)
#   subscribers | subs    bus subscriber slots (default 16, max 16)
#   overflow              fail | block | spill (default fail)
#   mode | permissions    octal file mode      (default 0600, e.g. mode=644)
#   framed | stream       stream length-prefix (framed=1 default; stream=1 = raw)
#   direction | read | write   fifo direction  (direction=read / ?write=1)
#   authenticate          unix peer uid check  (authenticate=1)

IPCMail.create("shm://jobs?capacity=64&bsize=512&overflow=block")
```

### create, open, close

```cr
require "ipcmail"

# create allocates the endpoint; open attaches to an existing one.
# both return an IPCMail::Mailbox on the generic path.
producer = IPCMail.create("shm://jobs")   # => Mailbox
consumer = IPCMail.open("shm://jobs")      # => Mailbox

producer.send("hello")
msg = consumer.receive                     # => Message
puts msg.text

consumer.close
producer.close   # last attachment to close unlinks the segment
```

### block form auto-closes

```cr
require "ipcmail"

# any create/open/listen with a block yields the endpoint and closes it after.
IPCMail.create("shm://jobs") do |mb|
  mb.send("work")
end   # closed here, even on raise

IPCMail.open("shm://jobs") do |mb|
  mb.receive?(1.second)
end
```

### typed variants (concrete class back, scheme asserted)

```cr
require "ipcmail"

# passing the class as the first arg narrows the return type and checks the
# scheme; a mismatch raises IPCMail::SchemeError with a corrective message.
shm  = IPCMail.open(IPCMail::SharedMemory, "shm://jobs")     # => SharedMemory
bus  = IPCMail.create(IPCMail::Bus, "bus://events?subs=8")   # => Bus
sock = IPCMail.open(IPCMail::Socket, "unix:///tmp/app.sock") # => Socket
pipe = IPCMail.create(IPCMail::Pipe, "fifo:///tmp/log", direction: :write) # => Pipe

# typed create/open also take a block:
IPCMail.create(IPCMail::SharedMemory, "shm://jobs") do |mb|
  mb.send("x")
end
```

### the three send forms

```cr
require "ipcmail"

mb = IPCMail.create(IPCMail::SharedMemory, "shm://q", blocks: 8)

# String
mb.send("text")

# Bytes, with metadata
mb.send("payload".to_slice, type: 7, priority: :high, timeout: 1.second)

# zero-copy: write straight into the reserved block, no intermediate buffer
mb.send(256) do |slice|      # slice : Bytes of exactly 256 bytes
  slice.copy_from("data".to_slice)
end

mb.close
```

### non-raising and timeout variants

```cr
require "ipcmail"

a = IPCMail.create(IPCMail::SharedMemory, "shm://q2", blocks: 4)
b = IPCMail.open(IPCMail::SharedMemory, "shm://q2")

# send? : Bool -- false on timeout, full mailbox, or a closed peer (never raises)
ok = a.send?("maybe", timeout: 10.milliseconds)

# receive  : Message  -- raises TimeoutError on miss
# receive? : Message? -- nil on miss
msg  = b.receive(1.second)
mby  = b.receive?(50.milliseconds)   # => Message?

b.close; a.close
```

### borrowed receive (no copy)

```cr
require "ipcmail"

a = IPCMail.create(IPCMail::SharedMemory, "shm://q3", blocks: 4)
b = IPCMail.open(IPCMail::SharedMemory, "shm://q3")
a.send("data", type: 1, priority: :high)

# the block form hands you a View: a window into the block, valid only inside
# the block. The block is released when the block returns.
b.receive do |view|          # view : IPCMail::View
  process(view.to_slice)     # view.text / view.to_slice / view.type / view.priority / view.size
  kept = view.copy           # view.copy -> Message if you need to retain it past the block
end

b.close; a.close
```

### draining a mailbox

```cr
require "ipcmail"

mb = IPCMail.open(IPCMail::SharedMemory, "shm://q")

# each pulls until a receive misses (with a timeout) or the mailbox closes
mb.each(timeout: 100.milliseconds) do |m|   # m : Message
  handle(m)
end

mb.close
```

### the Message value

```cr
require "ipcmail"

# a received Message exposes:
#   m.payload  : Bytes
#   m.type     : UInt32
#   m.priority : IPCMail::Priority (Normal | High)
#   m.size     : Int32
#   m.text     : String            (payload as UTF-8)
#   m.to_slice : Bytes
```

### full-duplex pair

```cr
require "ipcmail"

# two endpoints on one segment; each side both sends and receives.
a = IPCMail.create(IPCMail::SharedMemory, "shm://duplex", capacity: 16, block_size: 256, blocks: 16)
b = IPCMail.open(IPCMail::SharedMemory, "shm://duplex")

a.send("from a")
b.send("from b")
puts b.receive.text   # "from a"
puts a.receive.text   # "from b"

b.close; a.close
```

### priority ordering

```cr
require "ipcmail"

a = IPCMail.create(IPCMail::SharedMemory, "shm://prio", blocks: 8)
b = IPCMail.open(IPCMail::SharedMemory, "shm://prio")

a.send("low",  priority: :normal)
a.send("high", priority: :high)

# high-priority messages are dequeued first regardless of send order
puts b.receive.text   # "high"
puts b.receive.text   # "low"

b.close; a.close
```

### introspection

```cr
require "ipcmail"

mb = IPCMail.create(IPCMail::SharedMemory, "shm://intro")

mb.pending      # UInt32 -- messages waiting for THIS side to receive
mb.queued       # UInt32 -- messages THIS side has queued for the peer
mb.capacity     # UInt32
mb.block_size   # UInt32

mb.close
```

### publish to many subscribers

```cr
require "ipcmail"

bus = IPCMail.create(IPCMail::Bus, "bus://events?subs=16")

s1 = IPCMail.open(IPCMail::Bus, "bus://events"); s1.subscribe
s2 = IPCMail.open(IPCMail::Bus, "bus://events"); s2.subscribe

# publish returns the number of subscribers it reached (0 if none matched)
n = bus.publish("update", type: 1)   # => Int32

s1.receive { |v| puts v.text }
s2.receive { |v| puts v.text }

[s1, s2].each &.close
bus.close
```

### subscribe with type filters

```cr
require "ipcmail"

sub = IPCMail.open(IPCMail::Bus, "bus://events")

sub.subscribe               # all types
sub.subscribe(1, 2, 3)      # only these types (max 8 filters)
sub.subscribe([4, 5])       # Enumerable form

sub.subscribed?             # Bool
sub.slot                    # UInt32? -- assigned subscriber slot, nil if not subscribed
sub.pending                 # UInt32  -- queued messages for this subscriber

sub.unsubscribe             # release the slot (also done on close)
sub.close
```

### publish forms mirror send

```cr
require "ipcmail"

bus = IPCMail.create(IPCMail::Bus, "bus://pub?subs=4")

bus.publish("text", type: 1, priority: :high)
bus.publish("bytes".to_slice, type: 2)
bus.publish(128) { |slice| slice.copy_from("zero-copy".to_slice) }   # zero-copy

bus.block_size    # UInt32
bus.subscribers   # UInt32 -- live subscriber count on the segment

bus.close
```

### server accept loop

```cr
require "ipcmail"

# listen returns a Socket::Server. authenticate=1 rejects peers whose uid
# differs from the current user (raises PermissionDenied on accept).
server = IPCMail.listen("unix:///tmp/app.sock?authenticate=1")

server.each(timeout: 5.seconds) do |conn|   # conn : IPCMail::Socket
  msg = conn.receive(1.second)
  conn.send("ack", type: msg.type)
  conn.close
end

server.close   # deletes the socket file
```

### explicit accept + peer credentials

```cr
require "ipcmail"

server = IPCMail.listen("unix:///tmp/app.sock")

conn = server.accept(1.second)     # blocks up to timeout, raises TimeoutError on miss
# conn = server.accept?(1.second)  # => Socket? , nil on miss

creds = conn.peer_credentials      # => IPCMail::Credentials
creds.pid   # Int32
creds.uid   # UInt32
creds.gid   # UInt32

conn.close
server.close
```

### client connect

```cr
require "ipcmail"

# connect retries until the server is up or the timeout elapses
cli = IPCMail.open(IPCMail::Socket, "unix:///tmp/app.sock", timeout: 5.seconds)
cli.send("ping", type: 1)
reply = cli.receive(1.second)
cli.close
```

### raw (unframed) stream

```cr
require "ipcmail"

# framed=1 (default) length-prefixes each message so receive returns whole
# messages. stream=1 (or framed=0) is a raw byte stream: receive returns
# whatever bytes are available, one chunk at a time.
srv = IPCMail.listen("unix:///tmp/raw.sock?stream=1")
cli = IPCMail.open(IPCMail::Socket, "unix:///tmp/raw.sock?stream=1")
```

### anonymous pair (in-process / parent-child)

```cr
require "ipcmail"

# two connected Pipe endpoints backed by OS pipes; no filesystem name.
left, right = IPCMail::Pipe.pair(framed: true)

spawn do
  right.send("data")
  right.close
end

msg = left.receive(1.second)
left.close
```

### named FIFO with a direction

```cr
require "ipcmail"

# a fifo endpoint is one-directional; give it a direction.
# writer side:
writer = IPCMail.create(IPCMail::Pipe, "fifo:///tmp/log.fifo", direction: :write)
writer.send("line")
writer.close

# reader side (open blocks until a writer appears, up to timeout):
reader = IPCMail.open(IPCMail::Pipe, "fifo:///tmp/log.fifo", direction: :read, timeout: 5.seconds)
line = reader.receive(1.second)
reader.unlink   # remove the FIFO file
reader.close

# direction may also be given in the URI: fifo:///tmp/log.fifo?direction=read
# or the shorthand flags ?read=1 / ?write=1
```

### the three policies

```cr
require "ipcmail"

# overflow governs what happens when every block is in use at send time.
# In keyword args, pass the enum; in a URI, pass the string.

# :fail  -- raise FullError immediately (with no timeout) or TimeoutError
a = IPCMail.create(IPCMail::SharedMemory, "shm://o1", blocks: 4, overflow: IPCMail::Overflow::Fail)

# :block -- wait for a free block until the timeout elapses
b = IPCMail.create(IPCMail::SharedMemory, "shm://o2", blocks: 4, overflow: IPCMail::Overflow::Block)

# :spill -- (shm only) overflow goes to a side FIFO; a normal receive loop
#           drains it transparently, so no message is lost or reordered
c = IPCMail.create(IPCMail::SharedMemory, "shm://o3", blocks: 4, overflow: IPCMail::Overflow::Spill)

# URI form (string, no symbol):
d = IPCMail.create("shm://o4?blocks=4&overflow=block")

[a, b, c, d].each &.close
```

### spill is transparent to receive

```cr
require "ipcmail"

a = IPCMail.create(IPCMail::SharedMemory, "shm://spill", blocks: 1, overflow: IPCMail::Overflow::Spill)
b = IPCMail.open(IPCMail::SharedMemory, "shm://spill", overflow: IPCMail::Overflow::Spill)

a.send("first")    # fills the single block
a.send("second")   # spills to the side FIFO
a.send("third")    # spills too

# a plain receive loop sees all three, in order -- spill is not a separate channel
3.times { puts b.receive.text }

b.close; a.close
```

### live segment stats (read-only, non-participating)

```cr
require "ipcmail"

# monitor attaches to an shm:// or bus:// segment without joining traffic.
mon = IPCMail.monitor("bus://events")

st = mon.stats            # => IPCMail::Monitor::Stats
st.name             # String
st.kind             # IPCMail::Kind (PointToPoint | Bus)
st.capacity         # UInt32
st.block_size       # UInt32
st.block_count      # UInt32
st.blocks_in_use    # UInt32
st.subscribers      # UInt32
st.max_subscribers  # UInt32
st.trace_capacity   # UInt32
st.lanes            # Array(UInt32) -- depth of each of the 4 lanes
st.rings            # Array(Tuple(UInt32, UInt32, UInt32)) -- {slot, normal, high} per subscriber
st.usage            # Float64 -- blocks_in_use as a percentage

mon.close
```

### reading the trace ring

```cr
require "ipcmail"

# a segment created with trace > 0 records every send/receive.
seg = IPCMail.create(IPCMail::SharedMemory, "shm://traced", trace: 64)
peer = IPCMail.open(IPCMail::SharedMemory, "shm://traced")
seg.send("x")
peer.receive

# trace(limit) returns records since the last call (cursor advances).
# Bus and SharedMemory also expose #trace directly.
seg.trace(64).each do |r|      # r : IPCMail::TraceRecord
  r.at         # Time
  r.sequence   # UInt64
  r.type       # UInt32
  r.size       # UInt32
  r.priority   # IPCMail::Priority
  r.lane       # IPCMail::Lane  (A | B)
  r.event      # IPCMail::Event (Send | Receive)
  puts r       # "#12 TX lane=A type=0 size=1 priority=Normal"
end

peer.close; seg.close
```

### a plain mmap'd region (no messaging)

```cr
require "ipcmail"

# Buffer is a bare shared-memory region for when you want raw bytes, not a
# mailbox. Name must be a single leading slash + name.
buf = IPCMail::Buffer.create(4096, "/myapp-scratch")   # => Buffer
buf.to_slice[0] = 42_u8                                  # to_slice : Bytes (writable)

# attach read-only from another process
ro = IPCMail::Buffer.open("/myapp-scratch", read_only: true, timeout: 5.seconds)
ro.size        # Int64
ro.creator?    # Bool
ro.read_only?  # Bool
ro.to_slice    # Bytes (read-only)
ro.to_unsafe   # Pointer(UInt8) -- for regions larger than Int32::MAX
ro.close

buf.close   # creator close unlinks by default; close(unlink: false) to keep it
```

### auto-named + block form

```cr
require "ipcmail"

# omit the name to get a generated unique one (/ipcmail-<pid>-<hex>)
IPCMail::Buffer.create(1 << 20) do |buf|
  buf.to_slice   # ... use it ...
end   # closed and unlinked here

IPCMail::Buffer.unlink("/myapp-scratch")   # => Bool, explicit removal
```

### the exception hierarchy

```cr
require "ipcmail"

# all inherit IPCMail::Error < Exception
mb = IPCMail.open(IPCMail::SharedMemory, "shm://q")

begin
  mb.send("x", timeout: 100.milliseconds)
  msg = mb.receive(1.second)
rescue IPCMail::TimeoutError
  # send/receive/accept exceeded the timeout
rescue IPCMail::FullError
  # :fail overflow with no timeout, and no free block
rescue IPCMail::ClosedError
  # endpoint or peer is closed (stream peers also raise this mid-frame on stall)
rescue IPCMail::MessageTooLarge
  # payload exceeds block_size (shm/bus) or the frame limit (stream)
rescue IPCMail::SchemeError
  # wrong scheme for the verb / typed class
rescue IPCMail::CorruptSegment
  # segment magic/version/kind/layout mismatch on attach
rescue IPCMail::PermissionDenied
  # authenticate=1 and the peer uid did not match
rescue IPCMail::SystemError
  # a syscall failed; carries .errno : Errno
end

mb.close
```

### try-first patterns

```cr
require "ipcmail"

a = IPCMail.create(IPCMail::SharedMemory, "shm://try", blocks: 4)
b = IPCMail.open(IPCMail::SharedMemory, "shm://try")

# prefer send?/receive? where a miss is expected and not exceptional
if a.send?("event", timeout: 10.milliseconds)
  # queued
end

while m = b.receive?(50.milliseconds)   # nil ends the loop
  handle(m)
end

b.close; a.close
```

### reusing settings across endpoints

```cr
require "ipcmail"

# Config bundles the segment settings; SharedMemory/Bus .create take one
# directly, so you can define a profile once and reuse it.
config = IPCMail::Config.new(
  capacity: 64,       # ring capacity   (min 2)
  block_size: 512,    # bytes per block
  blocks: 128,        # block count
  trace: 256,         # trace ring      (0 = disabled)
  subscribers: 8,     # bus only        (min 1, max 16)
  overflow: :block,   # symbol autocasts here (typed Overflow parameter)
  mode: 0o600,
)

# NOTE: the class-level .create takes a bare segment NAME, not a URI.
# (The scheme dispatch lives only in the top-level IPCMail.create/.open.)
a = IPCMail::SharedMemory.create("profiled", config)
bus = IPCMail::Bus.create("profiled-bus", config)

a.close; bus.close
```