# src/ipcmail/types.cr
module IPCMail
  enum Priority : UInt8
    Normal = 0
    High   = 1
  end

  enum Overflow
    Fail
    Block
    Spill
  end

  enum Kind : UInt32
    PointToPoint = 0
    Bus          = 1
  end

  enum Lane : UInt8
    A = 0
    B = 1
  end

  enum Event : UInt8
    Send    = 0
    Receive = 1
  end

  struct Config
    getter capacity : UInt32
    getter block_size : UInt32
    getter blocks : UInt32
    getter trace : UInt32
    getter subscribers : UInt32
    getter overflow : Overflow
    getter mode : UInt32

    def initialize(capacity : Int = 32, block_size : Int = 256, blocks : Int = 64,
                   trace : Int = 0, subscribers : Int = LibIPC::MAX_SUBSCRIBERS,
                   @overflow : Overflow = :fail, mode : Int = 0o600)
      raise ArgumentError.new("capacity must be at least 2") if capacity < 2
      raise ArgumentError.new("block_size must be positive") if block_size < 1
      raise ArgumentError.new("blocks must be positive") if blocks < 1
      raise ArgumentError.new("subscribers must not exceed #{LibIPC::MAX_SUBSCRIBERS}") if subscribers > LibIPC::MAX_SUBSCRIBERS
      @capacity = capacity.to_u32
      @block_size = block_size.to_u32
      @blocks = blocks.to_u32
      @trace = trace.to_u32
      @subscribers = subscribers.to_u32
      @mode = mode.to_u32
    end
  end

  struct Deadline
    getter at : Time::Instant?

    def initialize(timeout : Time::Span? = nil)
      @at = timeout ? Time.instant + timeout : nil
    end

    def self.infinite : Deadline
      new(nil)
    end

    def expired? : Bool
      if at = @at
        Time.instant >= at
      else
        false
      end
    end

    def infinite? : Bool
      @at.nil?
    end

    def remaining : Time::Span?
      return nil unless at = @at
      span = at - Time.instant
      span < Time::Span.zero ? Time::Span.zero : span
    end

    def remaining(cap : Time::Span) : Time::Span
      if span = remaining
        span < cap ? span : cap
      else
        cap
      end
    end
  end

  struct Message
    getter payload : Bytes
    getter type : UInt32
    getter priority : Priority

    def initialize(@payload : Bytes, @type : UInt32 = 0_u32, @priority : Priority = :normal)
    end

    def size : Int32
      @payload.size
    end

    def text : String
      String.new(@payload)
    end

    def to_slice : Bytes
      @payload
    end

    def to_s(io : IO) : Nil
      io.write(@payload)
    end

    def inspect(io : IO) : Nil
      io << "#<" << self.class << " type=" << @type << " priority=" << @priority
      io << " size=" << size << '>'
    end
  end

  struct View
    getter payload : Bytes
    getter type : UInt32
    getter priority : Priority

    def initialize(@payload : Bytes, @type : UInt32, @priority : Priority)
    end

    def size : Int32
      @payload.size
    end

    def text : String
      String.new(@payload)
    end

    def to_slice : Bytes
      @payload
    end

    def copy : Message
      Message.new(@payload.dup, @type, @priority)
    end

    def to_s(io : IO) : Nil
      io.write(@payload)
    end
  end

  struct TraceRecord
    getter at : Time
    getter sequence : UInt64
    getter type : UInt32
    getter size : UInt32
    getter priority : Priority
    getter lane : Lane
    getter event : Event

    def initialize(record : LibIPC::Record)
      @at = Time.unix_ns(record.at)
      @sequence = record.seq
      @type = record.type
      @size = record.size
      @priority = Priority.from_value(record.priority)
      @lane = Lane.from_value(record.lane)
      @event = Event.from_value(record.event)
    end

    def to_s(io : IO) : Nil
      io << '#' << @sequence << ' ' << (@event.send? ? "TX" : "RX")
      io << " lane=" << @lane << " type=" << @type << " size=" << @size
      io << " priority=" << @priority
    end
  end

  struct Credentials
    getter pid : Int32
    getter uid : UInt32
    getter gid : UInt32

    def initialize(@pid : Int32, @uid : UInt32, @gid : UInt32)
    end
  end
end
