# src/ipcmail/bus.cr
module IPCMail
  class Bus < Mailbox
    WAIT_CAP = 100.milliseconds
    RETRY    = 500.microseconds

    getter segment : Segment
    getter overflow : Overflow
    getter? closed : Bool

    def self.create(name : String, capacity : Int = 32, block_size : Int = 256, blocks : Int = 64,
                    trace : Int = 0, subscribers : Int = LibIPC::MAX_SUBSCRIBERS,
                    overflow : Overflow = :fail, mode : Int = 0o600) : Bus
      create(name, Config.new(capacity: capacity, block_size: block_size, blocks: blocks,
        trace: trace, subscribers: subscribers, overflow: overflow, mode: mode))
    end

    def self.create(name : String, config : Config) : Bus
      segment = Segment.create(name, :bus, config)
      begin
        new(segment, config.overflow, config.mode)
      rescue error
        segment.close
        raise error
      end
    end

    def self.open(name : String, timeout : Time::Span? = 5.seconds,
                  overflow : Overflow = :fail, mode : Int = 0o600) : Bus
      segment = Segment.attach(name, :bus, timeout)
      begin
        new(segment, overflow, mode.to_u32)
      rescue error
        segment.close
        raise error
      end
    end

    protected def initialize(@segment : Segment, @overflow : Overflow, mode : UInt32)
      raise ArgumentError.new("a bus cannot spill, use :fail or :block") if @overflow.spill?
      @mode = mode
      @slot = nil.as(UInt32?)
      @inbox = nil.as(Signal?)
      @senders = {} of UInt32 => Signal::Sender
      @trace_cursor = 0_u64
      @closed = false
    end

    def block_size : UInt32
      @segment.block_size
    end

    def subscribers : UInt32
      @segment.subscriber_count
    end

    def subscribed? : Bool
      !@slot.nil?
    end

    def slot : UInt32?
      @slot
    end

    def pending : UInt32
      slot = @slot
      return 0_u32 unless slot
      @segment.subscriber_depth(slot, :normal) + @segment.subscriber_depth(slot, :high)
    end

    def subscribe : Nil
      subscribe([] of Int32)
    end

    def subscribe(*types : Int) : Nil
      subscribe(types.to_a)
    end

    def subscribe(types : Enumerable(Int)) : Nil
      check_open
      raise Error.new("already subscribed to #{@segment.name}") if @slot
      filters = types.map(&.to_u32).to_a
      if filters.size > LibIPC::MAX_TYPES
        raise ArgumentError.new("at most #{LibIPC::MAX_TYPES} type filters are supported")
      end

      slot = @segment.synchronize { @segment.claim_subscriber(filters) }
      raise FullError.new("no free subscriber slot on #{@segment.name}") unless slot

      begin
        @inbox = Signal.new(Signal.path_for(@segment.name, "sub#{slot}"), @mode)
      rescue error
        @segment.synchronize { @segment.release_subscriber(slot) }
        raise error
      end
      @slot = slot
    end

    def unsubscribe : Nil
      slot = @slot
      return unless slot
      @segment.synchronize { @segment.release_subscriber(slot) }
      if inbox = @inbox
        inbox.close
        inbox.unlink
      end
      @inbox = nil
      @slot = nil
    end

    def publish(payload : Bytes, *, type : Int = 0, priority : Priority = :normal,
                timeout : Time::Span? = nil) : Int32
      check_open
      guard(payload.size)
      dispatch(payload.size, type.to_u32, priority, Deadline.new(timeout)) do |slice|
        slice.copy_from(payload)
      end
    end

    def publish(payload : String, *, type : Int = 0, priority : Priority = :normal,
                timeout : Time::Span? = nil) : Int32
      publish(payload.to_slice, type: type, priority: priority, timeout: timeout)
    end

    def publish(size : Int, *, type : Int = 0, priority : Priority = :normal,
                timeout : Time::Span? = nil, & : Bytes ->) : Int32
      check_open
      guard(size)
      dispatch(size, type.to_u32, priority, Deadline.new(timeout)) { |slice| yield slice }
    end

    def receive(timeout : Time::Span? = nil, & : View -> _)
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

    def trace(limit : Int32 = 64) : Array(TraceRecord)
      records, @trace_cursor = @segment.read_trace(@trace_cursor, limit)
      records
    end

    def close : Nil
      return if @closed
      unsubscribe
      @closed = true
      @senders.each_value &.close
      @senders.clear
      @segment.close
    end

    def finalize
      close rescue nil
    end

    protected def write_message(payload : Bytes, type : UInt32, priority : Priority,
                                deadline : Deadline) : Bool
      check_open
      guard(payload.size)
      dispatch(payload.size, type, priority, deadline) { |slice| slice.copy_from(payload) }
      true
    end

    protected def read_message(deadline : Deadline) : Message?
      entry = dequeue(deadline)
      return nil unless entry
      descriptor, priority = entry
      payload = @segment.block(descriptor.block)[0, descriptor.size.to_i32].dup
      finish(descriptor.block)
      Message.new(payload, descriptor.type, priority)
    end

    private def guard(size : Int) : Nil
      return if size <= @segment.block_size
      raise MessageTooLarge.new("#{size} bytes exceeds the block size of #{@segment.block_size}")
    end

    private def dispatch(size : Int, type : UInt32, priority : Priority,
                         deadline : Deadline, & : Bytes ->) : Int32
      index = claim(deadline)
      begin
        yield @segment.block(index)[0, size.to_i32]
      rescue error
        @segment.synchronize { @segment.discard_block(index) }
        raise error
      end

      descriptor = LibIPC::Descriptor.new(block: index, size: size.to_u32, type: type)

      loop do
        delivered = @segment.synchronize do
          matched = [] of UInt32
          crowded = false

          @segment.each_subscriber do |slot, subscriber|
            next unless interested?(subscriber, type)
            if @segment.subscriber_full?(slot, priority)
              crowded = true
            else
              matched << slot
            end
          end

          if crowded && @overflow.block? && !deadline.expired?
            nil
          else
            if matched.empty?
              @segment.discard_block(index)
            else
              @segment.reference_block(index, matched.size.to_u32)
              matched.each { |slot| @segment.push_subscriber(slot, priority, descriptor) }
              @segment.trace(type, size.to_u32, priority, Lane::A, :send)
            end
            matched
          end
        end

        if delivered
          delivered.each { |slot| notify(slot) }
          return delivered.size
        end

        sleep RETRY
      end
    end

    private def claim(deadline : Deadline) : UInt32
      loop do
        if index = @segment.synchronize { @segment.claim_block }
          return index
        end

        if @overflow.fail? && deadline.infinite?
          raise FullError.new("every block of #{@segment.name} is in use, " \
                              "pass a timeout or use the :block overflow policy to wait for one")
        end

        raise TimeoutError.new("no free block in #{@segment.name}") if deadline.expired?
        sleep RETRY
      end
    end

    private def dequeue(deadline : Deadline) : Tuple(LibIPC::Descriptor, Priority)?
      check_open
      slot = @slot
      raise Error.new("not subscribed to #{@segment.name}") unless slot
      inbox = @inbox.not_nil!

      loop do
        inbox.drain

        entry = @segment.synchronize do
          priority = Priority::High
          descriptor = @segment.pop_subscriber(slot, :high)
          unless descriptor
            priority = Priority::Normal
            descriptor = @segment.pop_subscriber(slot, :normal)
          end

          if descriptor
            @segment.trace(descriptor.type, descriptor.size, priority, Lane::B, :receive)
            {descriptor, priority}
          end
        end

        return entry if entry
        return nil if deadline.expired?
        inbox.wait(deadline.remaining(WAIT_CAP))
      end
    end

    private def finish(index : UInt32) : Nil
      @segment.synchronize { @segment.release_block(index) }
    end

    private def interested?(subscriber : LibIPC::Subscriber, type : UInt32) : Bool
      return true if subscriber.types_size == 0
      subscriber.types_size.times do |position|
        return true if subscriber.types[position] == type
      end
      false
    end

    private def notify(slot : UInt32) : Nil
      sender = @senders[slot] ||= Signal::Sender.new(Signal.path_for(@segment.name, "sub#{slot}"))
      sender.notify
    end
  end
end
