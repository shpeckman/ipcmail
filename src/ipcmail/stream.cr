# src/ipcmail/stream.cr
module IPCMail
  abstract class Stream < Mailbox
    CHUNK = 65536
    LIMIT = 1 << 20

    getter? framed : Bool
    getter? closed : Bool

    @reader : IO?
    @writer : IO?

    protected def initialize(@reader : IO?, @writer : IO?, @framed : Bool,
                             @chunk : Int32 = CHUNK, @limit : Int32 = LIMIT)
      @read_lock  = Sync::Mutex.new
      @write_lock = Sync::Mutex.new
      @header     = Bytes.new(Framing::HEADER_SIZE)
      @consumed   = false
      @closed     = false
    end

    def readable? : Bool
      !@reader.nil?
    end

    def writable? : Bool
      !@writer.nil?
    end

    def fd : Int32
      io = @reader || @writer
      case io
      when IO::FileDescriptor then io.fd
      when ::Socket           then io.fd
      else                         raise ClosedError.new
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      writer  = @writer
      reader  = @reader
      writer.close if writer
      reader.close if reader && !reader.same?(writer)
    rescue IO::Error
    end

    def finalize
      close rescue nil
    end

    protected def write_message(payload : Bytes, type : UInt32, priority : Priority,
                                deadline : Deadline) : Bool
      check_open
      writer = @writer || raise Error.new("mailbox is receive only")

      @write_lock.synchronize do
        write_timeout(writer, deadline.remaining)
        if @framed
          Framing.write(writer, payload, type, priority)
        else
          writer.write(payload)
          writer.flush
        end
      end
      true
    rescue IO::TimeoutError
      false
    rescue error : IO::Error
      raise ClosedError.new(error.message || "the peer closed the connection")
    end

    protected def write_in_place(size : Int, type : UInt32, priority : Priority,
                                 deadline : Deadline, & : Bytes ->) : Bool
      check_open
      writer  = @writer || raise Error.new("mailbox is receive only")
      payload = Bytes.new(size)
      yield payload

      @write_lock.synchronize do
        write_timeout(writer, deadline.remaining)
        if @framed
          Framing.write(writer, payload, type, priority)
        else
          writer.write(payload)
          writer.flush
        end
      end
      true
    rescue IO::TimeoutError
      false
    rescue error : IO::Error
      raise ClosedError.new(error.message || "the peer closed the connection")
    end

    protected def read_message(deadline : Deadline) : Message?
      check_open
      reader = @reader || raise Error.new("mailbox is send only")

      @read_lock.synchronize do
        @framed ? read_frame(reader, deadline) : read_chunk(reader, deadline)
      end
    rescue error : IO::EOFError
      raise ClosedError.new("the peer closed the connection")
    rescue error : IO::Error
      raise error.is_a?(IO::TimeoutError) ? error : ClosedError.new(error.message || "broken transport")
    end

    private def read_chunk(reader : IO, deadline : Deadline) : Message?
      read_timeout(reader, deadline.remaining)
      buffer = Bytes.new(@chunk)
      count  = reader.read(buffer)
      raise IO::EOFError.new if count == 0
      Message.new(buffer[0, count].dup, 0_u32, Priority::Normal)
    rescue IO::TimeoutError
      nil
    end

    private def read_frame(reader : IO, deadline : Deadline) : Message?
      @consumed = false

      case fill(reader, @header, deadline, allow_empty: true)
      when Fill::Closed  then raise ClosedError.new("the peer closed the connection")
      when Fill::Timeout then return nil
      end

      head    = Framing.decode(@header, @limit)
      payload = Bytes.new(head.size)
      fill(reader, payload, deadline, allow_empty: false) if head.size > 0
      Message.new(payload, head.type, head.priority)
    rescue IO::TimeoutError
      raise ClosedError.new("the peer stalled mid-frame") if @consumed
      nil
    end

    private enum Fill
      Complete
      Timeout
      Closed
    end

    private def fill(reader : IO, buffer : Bytes, deadline : Deadline, allow_empty : Bool) : Fill
      filled = 0
      while filled < buffer.size
        read_timeout(reader, deadline.remaining)
        begin
          count = reader.read(buffer + filled)
        rescue IO::TimeoutError
          raise ClosedError.new("the peer stalled mid-frame") if @consumed || filled > 0
          return Fill::Timeout
        end

        if count == 0
          raise IO::EOFError.new unless filled == 0 && allow_empty && !@consumed
          return Fill::Closed
        end
        @consumed = true
        filled += count
      end
      Fill::Complete
    end

    private def read_timeout(io : IO, span : Time::Span?) : Nil
      case io
      when IO::FileDescriptor then io.read_timeout = span
      when ::Socket           then io.read_timeout = span
      end
    end

    private def write_timeout(io : IO, span : Time::Span?) : Nil
      case io
      when IO::FileDescriptor then io.write_timeout = span
      when ::Socket           then io.write_timeout = span
      end
    end
  end
end