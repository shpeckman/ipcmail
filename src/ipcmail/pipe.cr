# src/ipcmail/pipe.cr
module IPCMail
  class Pipe < Stream
    RETRY = 2.milliseconds

    enum Direction
      Read
      Write
    end

    getter path : String?

    def self.pair(framed : Bool = true) : Tuple(Pipe, Pipe)
      left_read, right_write = IO.pipe
      right_read, left_write = IO.pipe
      left_write.sync = false
      right_write.sync = false
      {new(left_read, left_write, framed), new(right_read, right_write, framed)}
    end

    def self.fifo(path : String, direction : Direction, framed : Bool = true,
                  timeout : Time::Span? = 5.seconds, mode : Int = 0o600) : Pipe
      permissions = mode.to_u32
      Signal.create(path, permissions)
      deadline = Deadline.new(timeout)

      flags = LibC::O_NONBLOCK | LibC::O_CLOEXEC
      flags |= direction.write? ? LibC::O_WRONLY : LibC::O_RDWR

      fd = -1
      loop do
        fd = LibC.open(path, flags, permissions)
        break if fd >= 0
        errno = Errno.value
        raise SystemError.new("open(#{path})", errno) unless errno.enxio?
        raise TimeoutError.new("no reader on #{path}") if deadline.expired?
        sleep RETRY
      end

      IO::FileDescriptor.set_blocking(fd, false)
      io = IO::FileDescriptor.new(fd)
      io.sync = false if direction.write?
      direction.write? ? new(nil, io, framed, path) : new(io, nil, framed, path)
    end

    protected def initialize(reader : IO::FileDescriptor?, writer : IO::FileDescriptor?,
                             framed : Bool, @path : String? = nil)
      super(reader, writer, framed)
    end

    def unlink : Nil
      if path = @path
        File.delete?(path)
      end
    end
  end
end