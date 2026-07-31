SNIPPETS: ipcmail
=================

### usage

```cr
require "ipcmail"

# ─── entry points ────────────────────────────────────────────────────────────
# every endpoint is addressed by a uri whose scheme picks the transport:
#   shm://   point to point shared memory   (create / open)
#   bus://   publish / subscribe            (create / open)
#   unix://  unix domain socket             (listen / open)
#   fifo://  named pipe                      (create / open)
# query params configure the endpoint and only matter on the creating side:
#   ?capacity= / ?msgs=        ring capacity in messages   (default 32)
#   ?block_size= / ?bsize=     max message size in bytes   (default 256)
#   ?blocks= / ?bcount=        number of blocks            (default 64)
#   ?trace=                    trace ring capacity         (default 0, off)
#   ?subscribers= / ?subs=     bus subscriber slots        (default 16)
#   ?overflow=                 fail | block | spill        (default fail)
#   ?mode= / ?permissions=     octal file mode             (default 0600)
#   ?framed= / ?stream=        length prefixed framing     (default framed)
#   ?direction= / ?read / ?write   fifo direction (required for fifo)
#   ?authenticate=             unix peer uid check
# create : shm / bus / fifo. returns IPCMail::Mailbox
mailbox = IPCMail.create("shm:///demo?msgs=16&bsize=512&trace=64",
  capacity: 16, block_size: 512, blocks: 32, trace: 64,
  subscribers: 8, overflow: IPCMail::Overflow::Fail, mode: 0o600,
  framed: true, timeout: 5.seconds) # : IPCMail::Mailbox
mailbox.close

# open : shm / bus / unix / fifo. returns IPCMail::Mailbox
mailbox = IPCMail.open("shm:///demo",
  overflow: IPCMail::Overflow::Fail, mode: 0o600,
  framed: true, timeout: 5.seconds) # : IPCMail::Mailbox
mailbox.close

# block forms auto close the endpoint on exit
IPCMail.create("shm:///demo") { |mb| } # mb : IPCMail::Mailbox
IPCMail.open("shm:///demo") { |mb| }   # mb : IPCMail::Mailbox

# listen : unix only. returns IPCMail::Socket::Server
server = IPCMail.listen("unix://./demo.sock",
  framed: true, authenticate: true,
  backlog: ::Socket::SOMAXCONN, mode: 0o600) # : IPCMail::Socket::Server
server.close
IPCMail.listen("unix://./demo.sock") { |srv| } # srv : IPCMail::Socket::Server

# monitor : read only attach to a live shm / bus segment
monitor = IPCMail.monitor("shm:///demo", timeout: 5.seconds) # : IPCMail::Monitor
monitor.close

# ─── IPCMail::Mailbox (shared by every transport) ────────────────────────────
IPCMail.open("shm:///demo") do |mailbox|
  # send bytes or a string
  mailbox.send("payload", type: 2, priority: :high, timeout: 5.seconds)      # : Nil
  mailbox.send("payload".to_slice, type: 2, priority: :normal)               # : Nil

  # zero copy send: fill the block in place, nothing is copied
  mailbox.send(11, type: 2, priority: :normal, timeout: 5.seconds) do |slice|
    # slice : Bytes  (exactly the size you asked for)
    slice.copy_from("hello world".to_slice)
  end                                                                        # : Nil

  # send? swallows TimeoutError / FullError and returns whether it went out
  mailbox.send?("payload", type: 2, priority: :normal, timeout: 1.second)    # : Bool

  # receive : raises IPCMail::TimeoutError on deadline. nil timeout waits forever
  message = mailbox.receive(5.seconds)                                       # : IPCMail::Message

  # receive? : returns nil instead of raising
  message = mailbox.receive?(5.seconds)                                      # : IPCMail::Message?

  # receive with block yields a zero copy View (borrowed, valid inside the block)
  mailbox.receive(5.seconds) do |view|
    # view : IPCMail::View
  end

  # each : loop until closed, yielding each message (per iteration timeout)
  mailbox.each(1.second) do |message|
    # message : IPCMail::Message
  end                                                                        # : Nil

  mailbox.closed?                                                            # : Bool
  mailbox.close                                                              # : Nil
end

# ─── IPCMail::Message (owned copy) ───────────────────────────────────────────
IPCMail.open("shm:///demo") do |mailbox|
  message = mailbox.receive(5.seconds)
  # message.payload  : Bytes
  # message.type     : UInt32
  # message.priority : IPCMail::Priority
  # message.size     : Int32
  # message.text     : String     (payload decoded as utf-8)
  # message.to_slice : Bytes
end

# ─── IPCMail::View (zero copy borrow, only valid inside the receive block) ────
IPCMail.open("shm:///demo") do |mailbox|
  mailbox.receive(5.seconds) do |view|
    # view.payload  : Bytes
    # view.type     : UInt32
    # view.priority : IPCMail::Priority
    # view.size     : Int32
    # view.text     : String
    # view.to_slice : Bytes
    # view.copy     : IPCMail::Message   (promote to an owned copy that outlives the block)
  end
end

# ─── IPCMail::SharedMemory (shm://) ──────────────────────────────────────────
IPCMail.create("shm:///demo?trace=64") do |mailbox|
  shm = mailbox.as(IPCMail::SharedMemory)
  # shm.segment     : IPCMail::Segment
  # shm.overflow    : IPCMail::Overflow
  # shm.block_size  : UInt32
  # shm.capacity    : UInt32
  # shm.pending     : UInt32   (messages waiting to be received)
  # shm.queued      : UInt32   (messages sent but not yet taken by the peer)
  # shm.closed?     : Bool

  # trace : drains new trace records since the last call (needs ?trace=N)
  shm.trace(limit: 64)                                        # : Array(IPCMail::TraceRecord)

  # overflow_receive? : read from the spill fifo (only with overflow: :spill)
  shm.overflow_receive?(1.second)                             # : IPCMail::Message?
end

# ─── IPCMail::Bus (bus://) ───────────────────────────────────────────────────
IPCMail.create("bus:///events?subs=8&trace=128") do |mailbox|
  bus = mailbox.as(IPCMail::Bus)
  # bus.segment    : IPCMail::Segment
  # bus.overflow   : IPCMail::Overflow
  # bus.block_size : UInt32
  # bus.subscribers : UInt32   (live subscriber count)
  # bus.subscribed? : Bool
  # bus.slot        : UInt32?  (this endpoint's own slot, if subscribed)
  # bus.pending     : UInt32   (messages queued for this subscriber)

  # subscribe : no args = every type, otherwise filter by type (max 8 filters)
  bus.subscribe                                     # : Nil  (all types)
  bus.subscribe(100, 200, 300)                      # : Nil  (splat of types)
  bus.subscribe([100, 200])                         # : Nil  (enumerable of types)
  bus.unsubscribe                                   # : Nil

  # publish : fans out to interested subscribers, returns how many received it
  bus.publish("body", type: 100, priority: :high, timeout: 5.seconds)        # : Int32
  bus.publish("body".to_slice, type: 100, priority: :normal)                 # : Int32
  bus.publish(4, type: 100) do |slice|              # zero copy publish
    # slice : Bytes
  end                                               # : Int32

  # receive block yields a View, same as any mailbox
  bus.receive(5.seconds) do |view|
    # view : IPCMail::View
  end

  bus.trace(limit: 64)                              # : Array(IPCMail::TraceRecord)
end

# ─── IPCMail::Socket (unix://) ───────────────────────────────────────────────
IPCMail.listen("unix://./demo.sock", authenticate: true) do |server|
  # server : IPCMail::Socket::Server
  # server.path    : String
  # server.framed? : Bool
  # server.closed? : Bool

  maybe = server.accept?(5.seconds)                 # : IPCMail::Socket? (nil on timeout)
  connection = server.accept(5.seconds)             # : IPCMail::Socket  (raises on timeout)

  server.each(5.seconds) do |accepted|
    # accepted : IPCMail::Socket
  end                                               # : Nil

  # a connection is a Mailbox, plus:
  # connection.path       : String
  # connection.peer_credentials : IPCMail::Credentials
  creds = connection.peer_credentials
  # creds.pid : Int32
  # creds.uid : UInt32
  # creds.gid : UInt32

  connection.send("reply", type: 1)                 # : Nil
  connection.receive(5.seconds)                     # : IPCMail::Message
  connection.close
end

# client side of a socket
IPCMail.open("unix://./demo.sock") do |client|
  client = client.as(IPCMail::Socket)
  client.send("hello", type: 1)                     # : Nil
end

# ─── IPCMail::Stream shared surface (Socket and Pipe) ────────────────────────
IPCMail.open("unix://./demo.sock") do |stream|
  stream = stream.as(IPCMail::Stream)
  # stream.framed?   : Bool
  # stream.readable? : Bool
  # stream.writable? : Bool
  # stream.fd        : Int32
  # stream.closed?   : Bool
end

# ─── IPCMail::Pipe (fifo://) ─────────────────────────────────────────────────
# fifo endpoints need a direction. open one end, the peer opens the other.
reader = IPCMail.open("fifo:///tmp/demo.fifo?direction=read")   # : IPCMail::Mailbox
writer = IPCMail.open("fifo:///tmp/demo.fifo?direction=write")  # : IPCMail::Mailbox
reader.close
writer.close

# direct construction of a fifo pair of endpoints
read_end = IPCMail::Pipe.fifo("/tmp/demo.fifo", IPCMail::Pipe::Direction::Read,
  framed: true, timeout: 5.seconds, mode: 0o600)                # : IPCMail::Pipe
# read_end.path : String?
read_end.unlink                                                 # : Nil  (remove the fifo file)
read_end.close

# an in process anonymous pipe pair (two connected endpoints, no filesystem)
left, right = IPCMail::Pipe.pair(framed: true)                  # : Tuple(IPCMail::Pipe, IPCMail::Pipe)
left.send("ping", type: 1)
right.receive(1.second)
left.close
right.close

# ─── IPCMail::Buffer (raw named shared memory for out of band payloads) ───────
# hand a Buffer name through a mailbox as a control message, map the bytes on
# the peer side. nothing large is ever copied through the ring.
buffer = IPCMail::Buffer.create(1024, name: "/demo-frame", mode: 0o600) # : IPCMail::Buffer
# buffer.name       : String
# buffer.size       : Int64
# buffer.creator?   : Bool
# buffer.read_only? : Bool
# buffer.closed?    : Bool
# buffer.to_slice   : Bytes            (raise if size > Int32::MAX)
# buffer.to_unsafe  : Pointer(UInt8)
buffer.to_slice.fill(0xff_u8)
buffer.unlink                                          # : Bool  (unlink now, keep mapping)
buffer.close(unlink: false)                            # : Nil   (nil = unlink iff creator)

# open an existing buffer by name (blocks up to timeout for it to appear)
IPCMail::Buffer.open("/demo-frame", read_only: true, timeout: 5.seconds) do |buf|
  # buf : IPCMail::Buffer
  pixels = buf.to_slice                                # : Bytes
end

# a self generated name, plus manual reclaim
buffer = IPCMail::Buffer.create(4096)                  # : IPCMail::Buffer  (name auto generated)
name = buffer.name
buffer.close(unlink: false)
IPCMail::Buffer.unlink(name)                           # : Bool  (true if removed)

# ─── IPCMail::Monitor (read only inspection of a live segment) ───────────────
monitor = IPCMail.monitor("shm:///demo")               # : IPCMail::Monitor
begin
  # monitor.segment : IPCMail::Segment
  # monitor.closed? : Bool

  stats = monitor.stats                                # : IPCMail::Monitor::Stats
  # stats.name            : String
  # stats.kind            : IPCMail::Kind
  # stats.capacity        : UInt32
  # stats.block_size      : UInt32
  # stats.block_count     : UInt32
  # stats.blocks_in_use   : UInt32
  # stats.subscribers     : UInt32
  # stats.max_subscribers : UInt32
  # stats.trace_capacity  : UInt32
  # stats.lanes           : Array(UInt32)                        (4 lane depths)
  # stats.rings           : Array(Tuple(UInt32, UInt32, UInt32)) (slot, normal, high)
  # stats.usage           : Float64                              (percent blocks in use)

  monitor.trace(limit: 64)                             # : Array(IPCMail::TraceRecord)
ensure
  monitor.close
end

# ─── IPCMail::TraceRecord (one trace ring entry) ─────────────────────────────
records = IPCMail.monitor("shm:///demo").trace
records.each do |record|
  # record.at       : Time
  # record.sequence : UInt64
  # record.type     : UInt32
  # record.size     : UInt32
  # record.priority : IPCMail::Priority
  # record.lane     : IPCMail::Lane
  # record.event    : IPCMail::Event
end

# ─── IPCMail::Config (explicit config instead of uri query params) ───────────
config = IPCMail::Config.new(capacity: 32, block_size: 256, blocks: 64,
  trace: 0, subscribers: 16, overflow: :fail, mode: 0o600)
# config.capacity    : UInt32
# config.block_size  : UInt32
# config.blocks      : UInt32
# config.trace       : UInt32
# config.subscribers : UInt32
# config.overflow    : IPCMail::Overflow
# config.mode        : UInt32
IPCMail::SharedMemory.create("/demo", config)          # : IPCMail::SharedMemory
IPCMail::Bus.create("/events", config)                 # : IPCMail::Bus

# ─── enums and value types ───────────────────────────────────────────────────
# IPCMail::Priority : UInt8   -> Normal (0) | High (1)
# IPCMail::Overflow          -> Fail | Block | Spill
# IPCMail::Kind : UInt32      -> PointToPoint (0) | Bus (1)
# IPCMail::Lane : UInt8       -> A (0) | B (1)
# IPCMail::Event : UInt8      -> Send (0) | Receive (1)

# ─── errors (all descend from IPCMail::Error < Exception) ────────────────────
begin
  IPCMail.open("shm:///missing", timeout: 100.milliseconds)
rescue ex : IPCMail::TimeoutError    # deadline elapsed
rescue ex : IPCMail::ClosedError     # endpoint / peer closed
rescue ex : IPCMail::FullError       # every block in use (overflow: :fail)
rescue ex : IPCMail::MessageTooLarge # payload exceeds the block size
rescue ex : IPCMail::CorruptSegment  # segment layout mismatch
rescue ex : IPCMail::PermissionDenied # peer failed uid authentication
rescue ex : IPCMail::SystemError     # ex.errno : Errno  (syscall failure)
rescue ex : IPCMail::Error           # base type for everything above
end
```