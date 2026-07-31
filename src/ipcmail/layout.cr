# src/ipcmail/layout.cr
module IPCMail
  struct Layout
    ALIGNMENT = 64_i64

    getter capacity : UInt32
    getter block_size : UInt32
    getter block_count : UInt32
    getter trace_capacity : UInt32
    getter max_subscribers : UInt32
    getter descriptors : Int64
    getter subscriptions : Int64
    getter owners : Int64
    getter references : Int64
    getter blocks : Int64
    getter trace : Int64
    getter bytes : Int64

    def initialize(@capacity : UInt32, @block_size : UInt32, @block_count : UInt32,
                   @trace_capacity : UInt32, @max_subscribers : UInt32)
      descriptor = sizeof(LibIPC::Descriptor).to_i64
      cursor = align(sizeof(LibIPC::Header).to_i64)
      @descriptors = cursor
      cursor = align(cursor + 4_i64 * @capacity.to_i64 * descriptor)
      @subscriptions = cursor
      cursor = align(cursor + 2_i64 * @max_subscribers.to_i64 * @capacity.to_i64 * descriptor)
      @owners = cursor
      cursor = align(cursor + 4_i64 * @block_count.to_i64)
      @references = cursor
      cursor = align(cursor + 4_i64 * @block_count.to_i64)
      @blocks = cursor
      cursor = align(cursor + @block_count.to_i64 * @block_size.to_i64)
      @trace = cursor
      @bytes = align(cursor + @trace_capacity.to_i64 * sizeof(LibIPC::Record).to_i64)
    end

    def self.from(config : Config, kind : Kind) : Layout
      new(config.capacity, config.block_size, config.blocks, config.trace,
        kind.bus? ? config.subscribers : 0_u32)
    end

    def self.from(header : LibIPC::Header) : Layout
      new(header.capacity, header.block_size, header.block_count,
        header.trace_capacity, header.max_subscribers)
    end

    private def align(value : Int64) : Int64
      (value + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
    end
  end
end