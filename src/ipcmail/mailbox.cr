# src/ipcmail/mailbox.cr
abstract class IPCMail::Mailbox
  abstract def close : Nil
  abstract def closed? : Bool

  protected abstract def write_message(payload : Bytes, type : UInt32, priority : Priority,
                                       deadline : Deadline) : Bool
  protected abstract def write_in_place(size : Int, type : UInt32, priority : Priority,
                                        deadline : Deadline, & : Bytes ->) : Bool
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
    unless write_in_place(size, type.to_u32, priority, Deadline.new(timeout)) { |slice| yield slice }
      raise TimeoutError.new("send timed out")
    end
  end

  def send?(payload : Bytes | String, *, type : Int = 0, priority : Priority = :normal,
            timeout : Time::Span? = nil) : Bool
    send(payload, type: type, priority: priority, timeout: timeout)
    true
  rescue TimeoutError | FullError | ClosedError | MessageTooLarge
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

  HANDLE_TYPE = 0xFFFFFF01_u32

  def send_large(payload : Bytes, *, priority : Priority = :normal,
                 timeout : Time::Span? = nil, mode : Int = 0o600) : Nil
    buffer = Buffer.create(payload.size, mode: mode)
    begin
      buffer.to_slice.copy_from(payload)
      handle = Handle.new(buffer.name, payload.size.to_i64)
      send(handle.to_slice, type: HANDLE_TYPE, priority: priority, timeout: timeout)
    rescue error
      buffer.close(unlink: true)
      raise error
    ensure
      buffer.close(unlink: false)
    end
  end

  def send_large(payload : String, **options) : Nil
    send_large(payload.to_slice, **options)
  end

  def receive_large(timeout : Time::Span? = nil) : Message
    message = receive(timeout)
    return message unless message.type == HANDLE_TYPE

    handle = Handle.decode(message.payload)
    Buffer.open(handle.name, read_only: true) do |buffer|
      begin
        Message.new(buffer.to_slice[0, handle.size.to_i32].dup, 0_u32, message.priority)
      ensure
        Buffer.unlink(handle.name)
      end
    end
  end

  def receive_large?(timeout : Time::Span? = nil) : Message?
    receive_large(timeout)
  rescue TimeoutError
    nil
  end

  protected def check_open : Nil
    raise ClosedError.new if closed?
  end
end
