# src/ipcmail/pty.cr
module IPCMail
  class Pty < Stream
    NAME_LIMIT = 128

    struct Winsize
      getter rows     : UInt16
      getter columns  : UInt16
      getter x_pixels : UInt16
      getter y_pixels : UInt16

      def initialize(rows : Int, columns : Int, x_pixels : Int = 0, y_pixels : Int = 0)
        raise ArgumentError.new("rows must not be negative") if rows < 0
        raise ArgumentError.new("columns must not be negative") if columns < 0
        @rows     = rows.to_u16
        @columns  = columns.to_u16
        @x_pixels = x_pixels.to_u16
        @y_pixels = y_pixels.to_u16
      end

      def to_s(io : IO) : Nil
        io << @rows << 'x' << @columns
      end
    end

    getter slave_path : String
    getter? master    : Bool

    def self.open(framed : Bool = false, raw : Bool = true, rows : Int? = nil,
                  columns : Int? = nil) : Pty
      descriptor = LibIPC.posix_openpt(LibC::O_RDWR | LibIPC::O_NOCTTY)
      raise SystemError.new("posix_openpt") if descriptor < 0

      path = begin
        raise SystemError.new("grantpt") unless LibIPC.grantpt(descriptor) == 0
        raise SystemError.new("unlockpt") unless LibIPC.unlockpt(descriptor) == 0
        slave_name(descriptor)
      rescue error
        LibC.close(descriptor)
        raise error
      end

      configure(new(adopt(descriptor), path, framed, true), raw, rows, columns)
    end

    def self.attach(path : String, framed : Bool = false, raw : Bool = false,
                    rows : Int? = nil, columns : Int? = nil) : Pty
      flags      = LibC::O_RDWR | LibIPC::O_NOCTTY | LibC::O_CLOEXEC | LibC::O_NONBLOCK
      descriptor = LibC.open(path, flags, 0o600u32)
      raise SystemError.new("open(#{path})") if descriptor < 0

      configure(new(adopt(descriptor), path, framed, false), raw, rows, columns)
    end

    def self.pair(framed : Bool = false, raw : Bool = true, rows : Int? = nil,
                  columns : Int? = nil) : Tuple(Pty, Pty)
      master = open(framed: framed, raw: raw, rows: rows, columns: columns)
      begin
        {master, attach(master.slave_path, framed: framed)}
      rescue error
        master.close
        raise error
      end
    end

    protected def initialize(io : IO::FileDescriptor, @slave_path : String, framed : Bool,
                             @master : Bool)
      super(io, io, framed)
    end

    def slave? : Bool
      !@master
    end

    def winsize : Winsize
      size = LibIPC::Winsize.new
      control(LibIPC::TIOCGWINSZ, pointerof(size), "ioctl(TIOCGWINSZ)")
      Winsize.new(size.ws_row, size.ws_col, size.ws_xpixel, size.ws_ypixel)
    end

    def winsize=(value : Winsize) : Winsize
      size = LibIPC::Winsize.new
      size.ws_row = value.rows
      size.ws_col = value.columns
      size.ws_xpixel = value.x_pixels
      size.ws_ypixel = value.y_pixels
      control(LibIPC::TIOCSWINSZ, pointerof(size), "ioctl(TIOCSWINSZ)")
      value
    end

    def resize(rows : Int? = nil, columns : Int? = nil, x_pixels : Int? = nil,
               y_pixels : Int? = nil) : Nil
      current = winsize
      self.winsize = Winsize.new(rows || current.rows, columns || current.columns,
        x_pixels || current.x_pixels, y_pixels || current.y_pixels)
    end

    def raw! : Nil
      attributes = attributes()
      LibC.cfmakeraw(pointerof(attributes))
      apply(attributes)
    end

    def raw? : Bool
      attributes().c_lflag & (LibC::ICANON | LibC::ECHO) == 0
    end

    private def attributes : LibC::Termios
      check_open
      attributes = LibC::Termios.new
      raise SystemError.new("tcgetattr") unless LibC.tcgetattr(fd, pointerof(attributes)) == 0
      attributes
    end

    private def apply(attributes : LibC::Termios) : Nil
      check_open
      raise SystemError.new("tcsetattr") unless LibC.tcsetattr(fd, LibC::TCSANOW, pointerof(attributes)) == 0
    end

    private def control(request : UInt64, size : LibIPC::Winsize*, context : String) : Nil
      check_open
      raise SystemError.new(context) unless LibIPC.ioctl(fd, LibC::ULong.new(request), size.as(Void*)) == 0
    end

    private def self.configure(pty : Pty, raw : Bool, rows : Int?, columns : Int?) : Pty
      pty.raw! if raw
      pty.resize(rows, columns) if rows || columns
      pty
    rescue error
      pty.close
      raise error
    end

    private def self.adopt(descriptor : Int32) : IO::FileDescriptor
      IO::FileDescriptor.set_blocking(descriptor, false)
      io = IO::FileDescriptor.new(descriptor)
      io.sync = false
      io
    end

    private def self.slave_name(descriptor : Int32) : String
      {% if flag?(:linux) %}
        buffer = Bytes.new(NAME_LIMIT)
        result = LibIPC.ptsname_r(descriptor, buffer.to_unsafe.as(LibC::Char*), LibC::SizeT.new(buffer.size))
        raise SystemError.new("ptsname_r", Errno.new(result)) unless result == 0
        String.new(buffer.to_unsafe)
      {% else %}
        name = LibIPC.ptsname(descriptor)
        raise SystemError.new("ptsname") if name.null?
        String.new(name)
      {% end %}
    end
  end
end
