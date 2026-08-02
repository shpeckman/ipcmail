# src/ipcmail/framing.cr
module IPCMail::Framing
  FORMAT      = IO::ByteFormat::SystemEndian
  HEADER_SIZE = 12

  record Head, size : UInt32, type : UInt32, priority : Priority

  def self.write(io : IO, payload : Bytes, type : UInt32, priority : Priority) : Nil
    io.write_bytes(payload.size.to_u32, FORMAT)
    io.write_bytes(type, FORMAT)
    io.write_bytes(priority.value.to_u32, FORMAT)
    io.write(payload)
    io.flush
  end

  def self.decode(header : Bytes, limit : Int32) : Head
    size = FORMAT.decode(UInt32, header[0, 4])
    type = FORMAT.decode(UInt32, header[4, 4])
    priority = FORMAT.decode(UInt32, header[8, 4])
    raise MessageTooLarge.new("frame of #{size} bytes exceeds #{limit}") if size > limit
    Head.new(size, type, Priority.from_value(priority.to_u8))
  end

  def self.read(io : IO, limit : Int32) : Message
    header = Bytes.new(HEADER_SIZE)
    io.read_fully(header)
    head = decode(header, limit)
    payload = Bytes.new(head.size)
    io.read_fully(payload) if head.size > 0
    Message.new(payload, head.type, head.priority)
  end
end