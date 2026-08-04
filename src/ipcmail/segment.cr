# src/ipcmail/segment.cr
class IPCMail::Segment
  MAGIC        = 0x49504d42_u32
  VERSION      =          6_u32
  STALL        = 250.milliseconds
  LOCK_WAIT    = 50.milliseconds
  ATTACH_RETRY = 500.microseconds

  getter name     : String
  getter layout   : Layout
  getter kind     : Kind
  getter? creator : Bool
  getter? closed  : Bool

  @base   : Pointer(UInt8)
  @header : Pointer(LibIPC::Header)

  def self.create(name : String, kind : Kind, config : Config) : Segment
    layout = Layout.from(config, kind)
    fd     = LibIPC.shm_open(name, LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL, config.mode)
    if fd < 0
      errno = Errno.value
      if errno.eexist?
        raise Error.new("segment #{name} already exists, attach to it with IPCMail.open")
      end
      raise SystemError.new("shm_open(#{name})", errno)
    end

    begin
      raise SystemError.new("ftruncate(#{name})") if LibC.ftruncate(fd, layout.bytes) < 0
      base = map(fd, layout.bytes)
    rescue error
      LibC.close(fd)
      LibIPC.shm_unlink(name)
      raise error
    end

    segment = new(name, fd, base, layout, kind, true)
    segment.prepare(config)
    segment
  end

  def self.attach(name : String, kind : Kind, timeout : Time::Span?) : Segment
    deadline = Deadline.new(timeout)
    fd       = -1

    loop do
      fd = LibIPC.shm_open(name, LibC::O_RDWR, 0_u32)
      break if fd >= 0
      errno = Errno.value
      raise SystemError.new("shm_open(#{name})", errno) unless errno.enoent?
      raise TimeoutError.new("no segment named #{name}") if deadline.expired?
      sleep ATTACH_RETRY
    end

    stat = uninitialized LibC::Stat
    if LibC.fstat(fd, pointerof(stat)) < 0
      errno = Errno.value
      LibC.close(fd)
      raise SystemError.new("fstat(#{name})", errno)
    end

    size = stat.st_size.to_i64
    if size < sizeof(LibIPC::Header)
      LibC.close(fd)
      raise CorruptSegment.new("segment #{name} is too small")
    end

    base = begin
      map(fd, size)
    rescue error
      LibC.close(fd)
      raise error
    end

    header = base.as(LibIPC::Header*)
    ready  = (base + offsetof(LibIPC::Header, @ready)).as(Atomic(UInt32)*)

    until ready.value.get(:acquire) == 1
      magic = header.value.magic
      if magic != 0 && magic != MAGIC
        munmap(base, size)
        LibC.close(fd)
        raise CorruptSegment.new("#{name} is not an ipcmail segment")
      end

      if deadline.expired?
        munmap(base, size)
        LibC.close(fd)
        raise TimeoutError.new("segment #{name} is not initialized")
      end
      sleep ATTACH_RETRY
    end

    layout = Layout.from(header.value)

    unless header.value.magic == MAGIC
      munmap(base, size)
      LibC.close(fd)
      raise CorruptSegment.new("#{name} is not an ipcmail segment")
    end

    if header.value.version != VERSION
      version = header.value.version
      munmap(base, size)
      LibC.close(fd)
      raise CorruptSegment.new("segment #{name} is version #{version}, expected #{VERSION}")
    end

    if header.value.kind != kind.value
      actual = Kind.from_value?(header.value.kind)
      munmap(base, size)
      LibC.close(fd)
      raise SchemeError.new("segment #{name} is a #{actual || "unknown"} segment, not #{kind}")
    end

    unless layout.bytes == size
      munmap(base, size)
      LibC.close(fd)
      raise CorruptSegment.new("segment #{name} does not match the expected layout")
    end

    segment = new(name, fd, base, layout, kind, false)
    segment.attach_flag.value.add(1_u32, :acquire_release)
    segment.sweep
    segment
  end

  private def self.map(fd : Int32, size : Int64) : Pointer(UInt8)
    address = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(size),
      LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_SHARED, fd, LibC::OffT.new(0))
    raise SystemError.new("mmap") if address == LibC::MAP_FAILED
    address.as(UInt8*)
  end

  private def self.munmap(base : Pointer(UInt8), size : Int64) : Nil
    LibC.munmap(base.as(Void*), LibC::SizeT.new(size))
  end

  private def initialize(@name : String, @fd : Int32, @base : Pointer(UInt8),
                         @layout : Layout, @kind : Kind, @creator : Bool)
    @header       = @base.as(LibIPC::Header*)
    @claim_cursor = 0_u32
    @closed       = false
  end

  protected def prepare(config : Config) : Nil
    LibIPC.memset(@base.as(Void*), 0, LibC::SizeT.new(@layout.bytes))
    LibIPC.sem_init(lock_semaphore, 1, 1)
    LibIPC.sem_init(recovery_semaphore, 1, 1)
    @header.value.magic = MAGIC
    @header.value.version = VERSION
    @header.value.kind = @kind.value
    @header.value.capacity = @layout.capacity
    @header.value.block_size = @layout.block_size
    @header.value.block_count = @layout.block_count
    @header.value.trace_capacity = @layout.trace_capacity
    @header.value.max_subscribers = @layout.max_subscribers
    attach_flag.value.set(1_u32, :relaxed)
    Atomic.fence
    ready_flag.value.set(1_u32, :release)
  end

  def capacity : UInt32
    @layout.capacity
  end

  def block_size : UInt32
    @layout.block_size
  end

  def trace_capacity : UInt32
    @layout.trace_capacity
  end

  def max_subscribers : UInt32
    @layout.max_subscribers
  end

  def subscriber_count : UInt32
    @header.value.subscriber_count
  end

  def register_endpoint : Int32
    synchronize do
      endpoints = endpoint_slots
      pid       = Process.pid.to_u32
      2.times do |slot|
        existing = endpoints[slot]
        next unless existing == 0 || !Process.exists?(existing.to_i32)
        endpoints[slot] = pid
        return slot
      end
      raise Error.new("segment #{@name} already has two live point-to-point endpoints")
    end
  end

  def release_endpoint(slot : Int32) : Nil
    return if slot < 0 || slot > 1
    synchronize { endpoint_slots[slot] = 0_u32 }
  end

  def owner_pid : UInt32
    owner_flag.value.get(:acquire)
  end

  def damaged? : Bool
    @header.value.damaged != 0
  end

  def attach_count : UInt32
    attach_flag.value.get(:acquire)
  end

  def generation : UInt32
    @header.value.generation
  end

  def synchronize(&)
    lock
    begin
      yield
    ensure
      unlock
    end
  end

  def lock : Nil
    return if try_lock
    started = Time.instant

    loop do
      case blocking_wait(LOCK_WAIT)
      when :acquired
        take_ownership
        return
      when :timeout
        if Time.instant - started > STALL
          steal_from_dead_owner
          started = Time.instant
        end
      when :interrupted
        # retry
      end
    end
  end

  def unlock : Nil
    owner_flag.value.set(0_u32, :release)
    LibIPC.sem_post(lock_semaphore)
  end

  private def try_lock : Bool
    return false unless LibIPC.sem_trywait(lock_semaphore) == 0
    take_ownership
    true
  end

  private def take_ownership : Nil
    owner_flag.value.set(Process.pid.to_u32, :release)
    if @header.value.damaged != 0
      @header.value.damaged = 0_u32
      recover
    end
  end

  private def blocking_wait(cap : Time::Span) : Symbol
    deadline = realtime_after(cap)
    result   = LibIPC.sem_timedwait(lock_semaphore, pointerof(deadline))
    return :acquired if result == 0

    errno = Errno.value
    case errno
    when Errno::ETIMEDOUT then :timeout
    when Errno::EINTR     then :interrupted
    else                       :interrupted
    end
  end

  private def realtime_after(span : Time::Span) : LibC::Timespec
    now = uninitialized LibC::Timespec
    LibIPC.clock_gettime(LibIPC::CLOCK_REALTIME, pointerof(now))
    nanos = now.tv_nsec.to_i64 + span.total_nanoseconds.to_i64
    ts = uninitialized LibC::Timespec
    ts.tv_sec = typeof(ts.tv_sec).new(now.tv_sec.to_i64 + nanos // 1_000_000_000)
    ts.tv_nsec = typeof(ts.tv_nsec).new(nanos % 1_000_000_000)
    ts
  end

  private def steal_from_dead_owner : Nil
    return unless LibIPC.sem_trywait(recovery_semaphore) == 0
    begin
      owner = owner_flag.value.get(:acquire)
      return if owner == 0
      return if Process.exists?(owner.to_i32)
      _, stolen = owner_flag.value.compare_and_set(owner, 0_u32)
      return unless stolen
      @header.value.damaged = 1_u32
      LibIPC.sem_post(lock_semaphore)
    ensure
      LibIPC.sem_post(recovery_semaphore)
    end
  end

  def sweep : Nil
    synchronize { recover }
  end

  private def recover : Nil
    @header.value.generation = @header.value.generation &+ 1_u32

    queues = queue_pointer
    4.times do |index|
      queue = queues[index]
      queue.head = 0_u32 if queue.head >= capacity
      queue.tail = 0_u32 if queue.tail >= capacity
      queues[index] = queue
    end

    owners     = block_owners
    references = block_references
    live       = Array(UInt32).new(@layout.block_count, 0_u32)

    max_subscribers.times do |slot|
      subscriber = subscribers[slot]
      next if subscriber.active == 0

      if subscriber.pid != 0 && !Process.exists?(subscriber.pid.to_i32)
        release_subscriber(slot.to_u32)
        next
      end

      rings = subscriber_rings(slot.to_u32)
      2.times do |priority|
        queue = rings[priority]
        queue.head = 0_u32 if queue.head >= capacity
        queue.tail = 0_u32 if queue.tail >= capacity
        rings[priority] = queue
        count_live(live, subscriber_descriptors(slot.to_u32, priority.to_u32), queue)
      end
    end

    if @kind.bus?
      @layout.block_count.times do |index|
        references[index] = live[index]
        owners[index] = 0_u32 if live[index] == 0
      end
      return
    end

    4.times do |lane|
      count_live(live, descriptors_for(lane), queues[lane])
    end

    @layout.block_count.times do |index|
      owner = owners[index]
      next if owner == 0
      next if live[index] > 0
      next if Process.exists?(owner.to_i32)
      owners[index] = 0_u32
      references[index] = 0_u32
    end
  end

  private def count_live(live : Array(UInt32), descriptors : Pointer(LibIPC::Descriptor),
                         queue : LibIPC::Queue) : Nil
    cursor = queue.tail
    while cursor != queue.head
      block = descriptors[cursor].block
      live[block] += 1 if block < @layout.block_count
      cursor = (cursor &+ 1) % capacity
    end
  end

  def claim_block : UInt32?
    owners     = block_owners
    references = block_references
    pid        = Process.pid.to_u32
    count      = @layout.block_count
    start      = @claim_cursor

    count.times do |offset|
      index = (start &+ offset) % count
      if owners[index] == 0 && references[index] == 0
        owners[index] = pid
        @claim_cursor = (index &+ 1) % count
        return index
      end
    end
    nil
  end

  def publish_barrier : Nil
    Atomic.fence(:release)
  end

  def discard_block(index : UInt32) : Nil
    block_references[index] = 0_u32
    block_owners[index] = 0_u32
  end

  def reference_block(index : UInt32, count : UInt32) : Nil
    block_references[index] = count
  end

  def adopt_block(index : UInt32) : Nil
    block_owners[index] = Process.pid.to_u32
  end

  def release_block(index : UInt32) : Nil
    references = block_references
    references[index] -= 1 if references[index] > 0
    block_owners[index] = 0_u32 if references[index] == 0
  end

  def blocks_in_use : UInt32
    owners = block_owners
    count  = 0_u32
    @layout.block_count.times { |index| count += 1 if owners[index] != 0 }
    count
  end

  def block(index : UInt32) : Bytes
    Bytes.new(@base + @layout.blocks + index.to_i64 * @layout.block_size, @layout.block_size)
  end

  def push(lane : Int32, descriptor : LibIPC::Descriptor) : Bool
    queues = queue_pointer
    queue  = queues[lane]
    return false if (queue.head &+ 1) % capacity == queue.tail
    descriptors_for(lane)[queue.head] = descriptor
    Atomic.fence
    queue.head = (queue.head &+ 1) % capacity
    queues[lane] = queue
    true
  end

  def pop(lane : Int32) : LibIPC::Descriptor?
    queues = queue_pointer
    queue  = queues[lane]
    return nil if queue.head == queue.tail
    descriptor = descriptors_for(lane)[queue.tail]
    queue.tail = (queue.tail &+ 1) % capacity
    queues[lane] = queue
    descriptor
  end

  def depth(lane : Int32) : UInt32
    queue = queue_pointer[lane]
    (queue.head &+ capacity &- queue.tail) % capacity
  end

  def push_subscriber(slot : UInt32, priority : Priority, descriptor : LibIPC::Descriptor) : Bool
    rings = subscriber_rings(slot)
    queue = rings[priority.value]
    return false if (queue.head &+ 1) % capacity == queue.tail
    subscriber_descriptors(slot, priority.value.to_u32)[queue.head] = descriptor
    Atomic.fence
    queue.head = (queue.head &+ 1) % capacity
    rings[priority.value] = queue
    true
  end

  def pop_subscriber(slot : UInt32, priority : Priority) : LibIPC::Descriptor?
    rings = subscriber_rings(slot)
    queue = rings[priority.value]
    return nil if queue.head == queue.tail
    descriptor = subscriber_descriptors(slot, priority.value.to_u32)[queue.tail]
    queue.tail = (queue.tail &+ 1) % capacity
    rings[priority.value] = queue
    descriptor
  end

  def subscriber_full?(slot : UInt32, priority : Priority) : Bool
    queue = subscriber_rings(slot)[priority.value]
    (queue.head &+ 1) % capacity == queue.tail
  end

  def subscriber_depth(slot : UInt32, priority : Priority) : UInt32
    queue = subscriber_rings(slot)[priority.value]
    (queue.head &+ capacity &- queue.tail) % capacity
  end

  def claim_subscriber(types : Array(UInt32)) : UInt32?
    max_subscribers.times do |index|
      slot       = index.to_u32
      subscriber = subscribers[slot]
      next unless subscriber.active == 0

      subscriber = LibIPC::Subscriber.new
      subscriber.active = 1_u32
      subscriber.pid = Process.pid.to_u32
      subscriber.types_size = types.size.to_u32
      types.each_with_index { |type, position| subscriber.types[position] = type }
      subscribers[slot] = subscriber
      @header.value.subscriber_count = @header.value.subscriber_count + 1
      return slot
    end
    nil
  end

  def release_subscriber(slot : UInt32) : Nil
    subscriber = subscribers[slot]
    return if subscriber.active == 0

    rings = subscriber_rings(slot)
    2.times do |priority|
      queue       = rings[priority]
      descriptors = subscriber_descriptors(slot, priority.to_u32)
      cursor      = queue.tail
      while cursor != queue.head
        release_block(descriptors[cursor].block)
        cursor = (cursor &+ 1) % capacity
      end
      rings[priority] = LibIPC::Queue.new
    end

    subscribers[slot] = LibIPC::Subscriber.new
    count = @header.value.subscriber_count
    @header.value.subscriber_count = count - 1 if count > 0
  end

  def each_subscriber(& : UInt32, LibIPC::Subscriber ->) : Nil
    max_subscribers.times do |index|
      slot       = index.to_u32
      subscriber = subscribers[slot]
      yield slot, subscriber if subscriber.active != 0
    end
  end

  def trace(type : UInt32, size : UInt32, priority : Priority, lane : Lane, event : Event) : Nil
    return if trace_capacity == 0
    sequence = @header.value.trace_seq
    record   = LibIPC::Record.new
    record.at = Time.utc.to_unix_ns
    record.seq = sequence
    record.type = type
    record.size = size
    record.priority = priority.value
    record.lane = lane.value
    record.event = event.value
    trace_records[sequence % trace_capacity] = record
    Atomic.fence
    @header.value.trace_seq = sequence + 1
  end

  def read_trace(cursor : UInt64, limit : Int32) : Tuple(Array(TraceRecord), UInt64)
    records = [] of TraceRecord
    return {records, cursor} if trace_capacity == 0

    synchronize do
      total    = @header.value.trace_seq
      oldest   = total > trace_capacity ? total - trace_capacity : 0_u64
      sequence = cursor < oldest ? oldest : cursor
      ring     = trace_records
      while sequence < total && records.size < limit
        records << TraceRecord.new(ring[sequence % trace_capacity])
        sequence += 1
      end
      cursor = total
    end

    {records, cursor}
  end

  def close : Bool
    return false if @closed
    @closed = true
    last    = attach_flag.value.sub(1_u32, :acquire_release) <= 1
    LibC.munmap(@base.as(Void*), LibC::SizeT.new(@layout.bytes))
    LibC.close(@fd)
    LibIPC.shm_unlink(@name) if last
    last
  end

  private def lock_semaphore : Void*
    @base.as(Void*)
  end

  private def recovery_semaphore : Void*
    (@base + offsetof(LibIPC::Header, @recovery)).as(Void*)
  end

  private def ready_flag : Pointer(Atomic(UInt32))
    (@base + offsetof(LibIPC::Header, @ready)).as(Atomic(UInt32)*)
  end

  private def owner_flag : Pointer(Atomic(UInt32))
    (@base + offsetof(LibIPC::Header, @owner)).as(Atomic(UInt32)*)
  end

  protected def attach_flag : Pointer(Atomic(UInt32))
    (@base + offsetof(LibIPC::Header, @attach_count)).as(Atomic(UInt32)*)
  end

  private def endpoint_slots : Pointer(UInt32)
    (@base + offsetof(LibIPC::Header, @endpoints)).as(UInt32*)
  end

  private def queue_pointer : Pointer(LibIPC::Queue)
    (@base + offsetof(LibIPC::Header, @queues)).as(LibIPC::Queue*)
  end

  private def subscribers : Pointer(LibIPC::Subscriber)
    (@base + offsetof(LibIPC::Header, @subscribers)).as(LibIPC::Subscriber*)
  end

  private def subscriber_rings(slot : UInt32) : Pointer(LibIPC::Queue)
    ((subscribers + slot).as(UInt8*) + offsetof(LibIPC::Subscriber, @rings)).as(LibIPC::Queue*)
  end

  private def descriptors_for(lane : Int32) : Pointer(LibIPC::Descriptor)
    (@base + @layout.descriptors).as(LibIPC::Descriptor*) + lane.to_i64 * capacity
  end

  private def subscriber_descriptors(slot : UInt32, priority : UInt32) : Pointer(LibIPC::Descriptor)
    offset = (slot.to_i64 * 2 + priority.to_i64) * capacity
    (@base + @layout.subscriptions).as(LibIPC::Descriptor*) + offset
  end

  private def block_owners : Pointer(UInt32)
    (@base + @layout.owners).as(UInt32*)
  end

  private def block_references : Pointer(UInt32)
    (@base + @layout.references).as(UInt32*)
  end

  private def trace_records : Pointer(LibIPC::Record)
    (@base + @layout.trace).as(LibIPC::Record*)
  end
end
