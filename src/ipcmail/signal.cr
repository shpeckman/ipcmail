# src/ipcmail/signal.cr
module IPCMail
  class Signal
    getter path : String
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
      @closed = false
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
    getter path : String

    def initialize(@path : String)
      @fd = -1
      @closed = false
    end

    def notify : Bool
      return false if @closed
      return false unless connect
      byte = 1_u8
      count = LibC.write(@fd, pointerof(byte).as(Void*), LibC::SizeT.new(1))
      return true if count == 1

      errno = Errno.value
      if errno.epipe? || errno.ebadf?
        LibC.close(@fd)
        @fd = -1
      end
      false
    end

    def close : Nil
      return if @closed
      @closed = true
      LibC.close(@fd) if @fd >= 0
      @fd = -1
    end

    private def connect : Bool
      return true if @fd >= 0
      fd = LibC.open(@path, LibC::O_WRONLY | LibC::O_NONBLOCK | LibC::O_CLOEXEC, 0o600_u32)
      return false if fd < 0
      @fd = fd
      true
    end
  end
end