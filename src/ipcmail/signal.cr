# src/ipcmail/signal.cr
module IPCMail
  class Signal
    getter path    : String
    getter? closed : Bool

    def self.path_for(name : String, tag : String) : String
      File.join(Dir.tempdir, "ipcmail.#{sanitize(name)}.#{tag}.fifo")
    end

    def self.sanitize(name : String) : String
      name.gsub(/[^A-Za-z0-9_.-]/, '_')
    end

    def self.create(path : String, mode : UInt32 = 0o600_u32) : Nil
      return if LibIPC.mkfifo(path, mode) == 0
      errno = Errno.value
      raise SystemError.new("mkfifo(#{path})", errno) unless errno.eexist?
    end

    def initialize(@path : String, mode : UInt32 = 0o600_u32)
      Signal.create(@path, mode)
      fd = LibC.open(@path, LibC::O_RDWR | LibC::O_NONBLOCK | LibC::O_CLOEXEC, mode)
      raise SystemError.new("open(#{@path})") if fd < 0
      IO::FileDescriptor.set_blocking(fd, false)
      @io = IO::FileDescriptor.new(fd)
      @io.read_buffering = false
      @io.sync = true
      @scratch = Bytes.new(64)
      @closed  = false
    end

    def drain : Nil
      return if @closed
      loop do
        count = LibC.read(@io.fd, @scratch.to_unsafe.as(Void*), LibC::SizeT.new(@scratch.size))
        break if count <= 0
      end
    end

    def wait(timeout : Time::Span?) : Bool
      return false if @closed
      @io.read_timeout = timeout
      @io.read(@scratch[0, 1])
      true
    rescue IO::TimeoutError
      false
    rescue IO::Error
      false
    end

    def close : Nil
      return if @closed
      @closed = true
      @io.close rescue nil
    end

    def unlink : Nil
      File.delete?(@path)
    end
  end

  class Signal::Sender
    enum Result
      Delivered
      NoReader
      Failed
    end

    getter path : String

    def initialize(@path : String)
      @fd     = -1
      @closed = false
    end

    def notify : Bool
      deliver == Result::Delivered
    end

    def deliver : Result
      return Result::Failed if @closed
      opened = connect
      return Result::NoReader if opened == Result::NoReader
      return Result::Failed if opened == Result::Failed

      result = attempt
      return result unless result == Result::Failed
      return Result::Failed unless reopen == Result::Delivered
      attempt
    end

    def close : Nil
      return if @closed
      @closed = true
      LibC.close(@fd) if @fd >= 0
      @fd = -1
    end

    private def attempt : Result
      byte  = 1_u8
      count = LibC.write(@fd, pointerof(byte).as(Void*), LibC::SizeT.new(1))
      return Result::Delivered if count == 1

      errno = Errno.value
      return Result::NoReader if errno.eagain?
      if errno.epipe? || errno.ebadf?
        LibC.close(@fd)
        @fd = -1
        return Result::Failed
      end
      Result::Failed
    end

    private def connect : Result
      return Result::Delivered if @fd >= 0
      fd = LibC.open(@path, LibC::O_WRONLY | LibC::O_NONBLOCK | LibC::O_CLOEXEC, 0o600_u32)
      if fd < 0
        return Errno.value.enxio? ? Result::NoReader : Result::Failed
      end
      @fd = fd
      Result::Delivered
    end

    private def reopen : Result
      LibC.close(@fd) if @fd >= 0
      @fd = -1
      connect
    end
  end
end
