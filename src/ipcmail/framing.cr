# src/ipcmail/framing.cr
module IPCMail
  module Framing
    FORMAT      = IO::ByteFormat::SystemEndian
    HEADER_SIZE = 12

    def self.write(io : IO, payload : Bytes, type : UInt32, priority : Priority) : Nil
      io.write_bytes(payload.size.to_u32, FORMAT)
      io.write_bytes(type, FORMAT)
      io.write_bytes(priority.value.to_u32, FORMAT)
      io.write(payload)
      io.flush
    end

    def self.read(io : IO, limit : Int32) : Message
      size = io.read_bytes(UInt32, FORMAT)
      type = io.read_bytes(UInt32, FORMAT)
      priority = io.read_bytes(UInt32, FORMAT)
      raise MessageTooLarge.new("frame of #{size} bytes exceeds #{limit}") if size > limit
      payload = Bytes.new(size)
      io.read_fully(payload) if size > 0
      Message.new(payload, type, Priority.from_value(priority.to_u8))
    end
  end
end