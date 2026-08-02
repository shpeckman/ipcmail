# src/ipcmail/shared_memory.cr
module IPCMail
  class SharedMemory < Mailbox
    WAIT_CAP    = 100.milliseconds
    SPILL_LIMIT = 1 << 20

    getter segment : Segment
    getter overflow : Overflow
    getter? closed : Bool

    def self.create(name : String, capacity : Int = 32, block_size : Int = 256, blocks : Int = 64,
                    trace : Int = 0, overflow : Overflow = :fail, mode : Int = 0o600) : SharedMemory
      create(name, Config.new(capacity: capacity, block_size: block_size, blocks: blocks,
        trace: trace, overflow: overflow, mode: mode))
    end

    def self.create(name : String, config : Config) : SharedMemory
      segment = Segment.create(name, :point_to_point, config)
      begin
        new(segment, config.overflow, config.mode)
      rescue error
        segment.close
        raise error
      end
    end

    def self.open(name : String, timeout : Time::Span? = 5.seconds,
                  overflow : Overflow = :fail, mode : Int = 0o600) : SharedMemory
      segment = Segment.attach(name, :point_to_point, timeout)
      begin
        new(segment, overflow, mode.to_u32)
      rescue error
        segment.close
        raise error
      end
    end

    protected def initialize(@segment : Segment, @overflow : Overflow, mode : UInt32)
      inbox, outbox = @segment.creator? ? {"a", "b"} : {"b", "a"}
      @inbox = Signal.new(Signal.path_for(@segment.name, inbox), mode)
      @outbox = Signal::Sender.new(Signal.path_for(@segment.name, outbox))
      @transmit_lane = @segment.creator? ? 0 : 2
      @receive_lane = @segment.creator? ? 2 : 0
      @mode = mode
      @spill = nil.as(IO::FileDescriptor?)
      @closed = false
    end

    def block_size : UInt32
      @segment.block_size
    end

    def capacity : UInt32
      @segment.capacity
    end

    def pending : UInt32
      @segment.depth(@receive_lane) + @segment.depth(@receive_lane + 1)
    end

    def queued : UInt32
      @segment.depth(@transmit_lane) + @segment.depth(@transmit_lane + 1)
    end

    protected def write_in_place(size : Int, type : UInt32, priority : Priority,
                                 deadline : Deadline, & : Bytes ->) : Bool
      check_open
      guard(size)
      transmit(size, type, priority, deadline) { |slice| yield slice }
    end

    def receive(timeout : Time::Span? = nil, & : View -> _)
      check_open
      if message = drain_spill
        yield View.new(message.payload, message.type, message.priority)
        return
      end

      entry = dequeue(Deadline.new(timeout))
      raise TimeoutError.new("receive timed out") unless entry
      descriptor, priority = entry
      begin
        yield View.new(@segment.block(descriptor.block)[0, descriptor.size.to_i32],
          descriptor.type, priority)
      ensure
        finish(descriptor.block)
      end
    end

    def overflow_receive?(timeout : Time::Span? = nil) : Message?
      io = spill_io
      io.read_timeout = Deadline.new(timeout).remaining
      Framing.read(io, SPILL_LIMIT)
    rescue IO::TimeoutError
      nil
    end

    def trace(limit : Int32 = 64) : Array(TraceRecord)
      records, @trace_cursor = @segment.read_trace(@trace_cursor, limit)
      records
    end

    def close : Nil
      return if @closed
      @closed = true
      @inbox.close
      @outbox.close
      @spill.try &.close
      if @segment.creator?
        @inbox.unlink
        File.delete?(Signal.path_for(@segment.name, "b"))
        File.delete?(Signal.path_for(@segment.name, "overflow"))
      end
      @segment.close
    end

    def finalize
      close rescue nil
    end

    protected def write_message(payload : Bytes, type : UInt32, priority : Priority,
                                deadline : Deadline) : Bool
      check_open
      guard(payload.size)
      transmit(payload.size, type, priority, deadline) { |slice| slice.copy_from(payload) }
    end

    protected def read_message(deadline : Deadline) : Message?
      check_open
      if message = drain_spill
        return message
      end

      entry = dequeue(deadline)
      return nil unless entry
      descriptor, priority = entry
      payload = @segment.block(descriptor.block)[0, descriptor.size.to_i32].dup
      finish(descriptor.block)
      Message.new(payload, descriptor.type, priority)
    end

    @trace_cursor = 0_u64

    private def guard(size : Int) : Nil
      return if size <= @segment.block_size
      raise MessageTooLarge.new("#{size} bytes exceeds the block size of #{@segment.block_size}")
    end

    private def transmit(size : Int, type : UInt32, priority : Priority,
                         deadline : Deadline, & : Bytes ->) : Bool
      index = claim(deadline)

      unless index
        buffer = Bytes.new(size)
        yield buffer
        return spill(buffer, type, priority, deadline)
      end

      begin
        yield @segment.block(index)[0, size.to_i32]
      rescue error
        @segment.synchronize { @segment.discard_block(index) }
        raise error
      end

      @segment.publish_barrier
      enqueue(index, size.to_u32, type, priority, deadline)
    end

    private def claim(deadline : Deadline) : UInt32?
      loop do
        @inbox.drain
        if index = @segment.synchronize { @segment.claim_block }
          return index
        end

        return nil if @overflow.spill?

        if @overflow.fail? && deadline.infinite?
          raise FullError.new("every block of #{@segment.name} is in use, " \
                              "pass a timeout or use the :block overflow policy to wait for one")
        end

        raise TimeoutError.new("no free block in #{@segment.name}") if deadline.expired?
        @inbox.wait(deadline.remaining(WAIT_CAP))
      end
    end

    private def enqueue(index : UInt32, size : UInt32, type : UInt32, priority : Priority,
                        deadline : Deadline) : Bool
      lane = @transmit_lane + priority.value.to_i32
      descriptor = LibIPC::Descriptor.new(block: index, size: size, type: type)

      loop do
        @inbox.drain
        stored = @segment.synchronize do
          if @segment.push(lane, descriptor)
            @segment.reference_block(index, 1_u32)
            @segment.trace(type, size, priority, transmit_lane, :send)
            true
          else
            false
          end
        end

        if stored
          @outbox.notify
          return true
        end

        if deadline.expired?
          @segment.synchronize { @segment.discard_block(index) }
          return false
        end

        @inbox.wait(deadline.remaining(WAIT_CAP))
      end
    end

    private def dequeue(deadline : Deadline) : Tuple(LibIPC::Descriptor, Priority)?
      loop do
        @inbox.drain

        entry = @segment.synchronize do
          priority = Priority::High
          descriptor = @segment.pop(@receive_lane + 1)
          unless descriptor
            priority = Priority::Normal
            descriptor = @segment.pop(@receive_lane)
          end

          if descriptor
            @segment.adopt_block(descriptor.block)
            @segment.trace(descriptor.type, descriptor.size, priority, receive_lane, :receive)
            {descriptor, priority}
          end
        end

        return entry if entry
        return nil if deadline.expired?
        @inbox.wait(deadline.remaining(WAIT_CAP))
      end
    end

    private def finish(index : UInt32) : Nil
      @segment.synchronize { @segment.release_block(index) }
      @outbox.notify
    end

    private def transmit_lane : Lane
      @transmit_lane == 0 ? Lane::A : Lane::B
    end

    private def receive_lane : Lane
      @receive_lane == 0 ? Lane::A : Lane::B
    end

    private def drain_spill : Message?
      return nil unless @overflow.spill?
      io = spill_io
      io.read_timeout = Time::Span.zero
      Framing.read(io, SPILL_LIMIT)
    rescue IO::TimeoutError
      nil
    rescue IO::EOFError
      nil
    end

    private def spill(payload : Bytes, type : UInt32, priority : Priority, deadline : Deadline) : Bool
      io = spill_io
      io.write_timeout = deadline.remaining
      Framing.write(io, payload, type, priority)
      true
    rescue IO::TimeoutError
      false
    end

    private def spill_io : IO::FileDescriptor
      io = @spill
      return io if io

      path = Signal.path_for(@segment.name, "overflow")
      Signal.create(path, @mode)
      fd = LibC.open(path, LibC::O_RDWR | LibC::O_NONBLOCK | LibC::O_CLOEXEC, @mode)
      raise SystemError.new("open(#{path})") if fd < 0
      IO::FileDescriptor.set_blocking(fd, false)
      io = IO::FileDescriptor.new(fd)
      io.read_buffering = false
      @spill = io
    end
  end
end