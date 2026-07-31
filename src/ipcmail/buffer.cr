# src/ipcmail/buffer.cr
module IPCMail
  class Buffer
    PREFIX   = "/ipcmail-"
    ATTEMPTS = 8
    RETRY    = 500.microseconds

    getter name : String
    getter size : Int64
    getter? creator : Bool
    getter? read_only : Bool
    getter? closed : Bool

    def self.create(size : Int, name : String? = nil, mode : Int = 0o600) : Buffer
      raise ArgumentError.new("size must be positive") if size < 1
      bytes = size.to_i64
      flags = LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL
      permissions = mode.to_u32
      chosen = ""
      fd = -1

      (name ? 1 : ATTEMPTS).times do
        chosen = name || generate
        validate(chosen)
        fd = LibIPC.shm_open(chosen, flags, permissions)
        break if fd >= 0
        errno = Errno.value
        raise SystemError.new("shm_open(#{chosen})", errno) if name || !errno.eexist?
      end
      raise SystemError.new("shm_open(#{chosen})", Errno::EEXIST) if fd < 0

      begin
        raise SystemError.new("ftruncate(#{chosen})") if LibC.ftruncate(fd, LibC::OffT.new(bytes)) < 0
        base = map(fd, bytes, false)
      rescue error
        LibC.close(fd)
        LibIPC.shm_unlink(chosen)
        raise error
      end

      new(chosen, fd, base, bytes, true, false)
    end

    def self.create(size : Int, name : String? = nil, mode : Int = 0o600, &)
      buffer = create(size, name, mode)
      begin
        yield buffer
      ensure
        buffer.close
      end
    end

    def self.open(name : String, read_only : Bool = false, timeout : Time::Span? = nil) : Buffer
      validate(name)
      deadline = Deadline.new(timeout)
      flags = read_only ? LibC::O_RDONLY : LibC::O_RDWR
      fd = -1

      loop do
        fd = LibIPC.shm_open(name, flags, 0_u32)
        break if fd >= 0
        errno = Errno.value
        raise SystemError.new("shm_open(#{name})", errno) unless errno.enoent? && timeout
        raise TimeoutError.new("no shared buffer named #{name}") if deadline.expired?
        sleep RETRY
      end

      stat = uninitialized LibC::Stat
      if LibC.fstat(fd, pointerof(stat)) < 0
        errno = Errno.value
        LibC.close(fd)
        raise SystemError.new("fstat(#{name})", errno)
      end

      bytes = stat.st_size.to_i64
      if bytes < 1
        LibC.close(fd)
        raise CorruptSegment.new("shared buffer #{name} is empty")
      end

      base = begin
        map(fd, bytes, read_only)
      rescue error
        LibC.close(fd)
        raise error
      end

      new(name, fd, base, bytes, false, read_only)
    end

    def self.open(name : String, read_only : Bool = false, timeout : Time::Span? = nil, &)
      buffer = open(name, read_only, timeout)
      begin
        yield buffer
      ensure
        buffer.close
      end
    end

    def self.unlink(name : String) : Bool
      return true if LibIPC.shm_unlink(name) == 0
      errno = Errno.value
      return false if errno.enoent?
      raise SystemError.new("shm_unlink(#{name})", errno)
    end

    def self.generate : String
      "#{PREFIX}#{Process.pid}-#{Random::Secure.hex(6)}"
    end

    def self.validate(name : String) : Nil
      unless name.starts_with?('/') && name.count('/') == 1 && name.size > 1
        raise ArgumentError.new("#{name.inspect} must be a single leading slash followed by a name")
      end
      raise ArgumentError.new("#{name.inspect} is too long") if name.bytesize > 255
    end

    private def self.map(fd : Int32, size : Int64, read_only : Bool) : Pointer(UInt8)
      protection = read_only ? LibC::PROT_READ : LibC::PROT_READ | LibC::PROT_WRITE
      address = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(size), protection,
        LibC::MAP_SHARED, fd, LibC::OffT.new(0))
      raise SystemError.new("mmap") if address == LibC::MAP_FAILED
      address.as(UInt8*)
    end

    private def initialize(@name : String, @fd : Int32, @base : Pointer(UInt8), @size : Int64,
                           @creator : Bool, @read_only : Bool)
      @closed = false
    end

    def to_slice : Bytes
      check_open
      if @size > Int32::MAX
        raise ArgumentError.new("#{@size} bytes cannot be sliced, use #to_unsafe")
      end
      Bytes.new(@base, @size.to_i32, read_only: @read_only)
    end

    def to_unsafe : Pointer(UInt8)
      check_open
      @base
    end

    def close(unlink : Bool? = nil) : Nil
      return if @closed
      @closed = true
      LibC.munmap(@base.as(Void*), LibC::SizeT.new(@size))
      LibC.close(@fd)
      Buffer.unlink(@name) if unlink.nil? ? @creator : unlink
    end

    def unlink : Bool
      Buffer.unlink(@name)
    end

    def finalize
      close rescue nil
    end

    def to_s(io : IO) : Nil
      io << "#<" << self.class << ' ' << @name << ' ' << @size << " bytes"
      io << " read-only" if @read_only
      io << '>'
    end

    private def check_open : Nil
      raise ClosedError.new("shared buffer #{@name} is closed") if @closed
    end
  end
end
