# src/ipcmail/monitor.cr
class IPCMail::Monitor
  struct Stats
    getter name            : String
    getter kind            : Kind
    getter capacity        : UInt32
    getter block_size      : UInt32
    getter block_count     : UInt32
    getter blocks_in_use   : UInt32
    getter subscribers     : UInt32
    getter max_subscribers : UInt32
    getter trace_capacity  : UInt32
    getter lanes           : Array(UInt32)
    getter rings           : Array(Tuple(UInt32, UInt32, UInt32))

    def initialize(@name, @kind, @capacity, @block_size, @block_count, @blocks_in_use,
                   @subscribers, @max_subscribers, @trace_capacity, @lanes, @rings)
    end

    def usage : Float64
      return 0.0 if @block_count == 0
      @blocks_in_use / @block_count.to_f * 100
    end
  end

  getter segment : Segment
  getter? closed : Bool

  def self.open(uri : String, timeout : Time::Span? = 5.seconds) : Monitor
    address = Address.parse(uri)
    kind = case address.scheme
           when "shm" then Kind::PointToPoint
           when "bus" then Kind::Bus
           else            raise ArgumentError.new("#{address.scheme}:// segments cannot be inspected")
           end
    new(Segment.attach(address.target, kind, timeout))
  end

  protected def initialize(@segment : Segment)
    @cursor = 0_u64
    @closed = false
  end

  def stats : Stats
    lanes = [] of UInt32
    rings = [] of Tuple(UInt32, UInt32, UInt32)

    @segment.synchronize do
      4.times { |lane| lanes << @segment.depth(lane) }
      @segment.each_subscriber do |slot, subscriber|
        rings << {slot, @segment.subscriber_depth(slot, :normal), @segment.subscriber_depth(slot, :high)}
      end

      Stats.new(@segment.name, @segment.kind, @segment.capacity, @segment.block_size,
        @segment.layout.block_count, @segment.blocks_in_use, @segment.subscriber_count,
        @segment.max_subscribers, @segment.trace_capacity, lanes, rings)
    end
  end

  def trace(limit : Int32 = 64) : Array(TraceRecord)
    records, @cursor = @segment.read_trace(@cursor, limit)
    records
  end

  def close : Nil
    return if @closed
    @closed = true
    @segment.close
  end

  def finalize
    close rescue nil
  end
end
