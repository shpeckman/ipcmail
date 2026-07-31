# src/ipcmail/mailbox.cr
module IPCMail
  abstract class Mailbox
    abstract def close : Nil
    abstract def closed? : Bool

    protected abstract def write_message(payload : Bytes, type : UInt32, priority : Priority,
                                         deadline : Deadline) : Bool
    protected abstract def read_message(deadline : Deadline) : Message?

    def send(payload : Bytes, *, type : Int = 0, priority : Priority = :normal,
             timeout : Time::Span? = nil) : Nil
      unless write_message(payload, type.to_u32, priority, Deadline.new(timeout))
        raise TimeoutError.new("send timed out")
      end
    end

    def send(payload : String, *, type : Int = 0, priority : Priority = :normal,
             timeout : Time::Span? = nil) : Nil
      send(payload.to_slice, type: type, priority: priority, timeout: timeout)
    end

    def send(size : Int, *, type : Int = 0, priority : Priority = :normal,
             timeout : Time::Span? = nil, & : Bytes ->) : Nil
      buffer = Bytes.new(size)
      yield buffer
      send(buffer, type: type, priority: priority, timeout: timeout)
    end

    def send?(payload : Bytes | String, *, type : Int = 0, priority : Priority = :normal,
              timeout : Time::Span? = nil) : Bool
      send(payload, type: type, priority: priority, timeout: timeout)
      true
    rescue TimeoutError | FullError
      false
    end

    def receive(timeout : Time::Span? = nil) : Message
      read_message(Deadline.new(timeout)) || raise TimeoutError.new("receive timed out")
    end

    def receive?(timeout : Time::Span? = nil) : Message?
      read_message(Deadline.new(timeout))
    end

    def receive(timeout : Time::Span? = nil, & : View -> _)
      message = receive(timeout)
      yield View.new(message.payload, message.type, message.priority)
    end

    def each(timeout : Time::Span? = nil, & : Message ->) : Nil
      loop do
        message = receive?(timeout)
        break unless message
        yield message
      end
    rescue ClosedError
    end

    protected def check_open : Nil
      raise ClosedError.new if closed?
    end
  end
end