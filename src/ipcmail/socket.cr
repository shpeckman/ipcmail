# src/ipcmail/socket.cr
module IPCMail
  class Socket < Stream
    RETRY = 2.milliseconds

    getter path : String

    def self.connect(path : String, framed : Bool = true,
                     timeout : Time::Span? = 5.seconds) : Socket
      deadline = Deadline.new(timeout)

      loop do
        begin
          socket = UNIXSocket.new(path)
          socket.sync = false
          return new(socket, path, framed)
        rescue error : ::Socket::Error | File::Error
          raise error if deadline.expired?
          sleep RETRY
        end
      end
    end

    protected def initialize(@socket : UNIXSocket, @path : String, framed : Bool)
      super(@socket, @socket, framed)
    end

    def peer_credentials : Credentials
      {% if flag?(:linux) %}
        credentials = LibIPC::Ucred.new
        size = LibC::SocklenT.new(sizeof(LibIPC::Ucred))
        result = LibC.getsockopt(@socket.fd, LibC::SOL_SOCKET, LibIPC::SO_PEERCRED,
          pointerof(credentials).as(Void*), pointerof(size))
        raise SystemError.new("getsockopt(SO_PEERCRED)") if result != 0
        Credentials.new(credentials.pid.to_i32, credentials.uid.to_u32, credentials.gid.to_u32)
      {% else %}
        uid = uninitialized LibC::UidT
        gid = uninitialized LibC::GidT
        raise SystemError.new("getpeereid") if LibIPC.getpeereid(@socket.fd, pointerof(uid), pointerof(gid)) != 0
        Credentials.new(nil, uid.to_u32, gid.to_u32)
      {% end %}
    end

    class Server
      getter path    : String
      getter? framed : Bool
      getter? closed : Bool

      def self.listen(path : String, framed : Bool = true, authenticate : Bool = false,
                      backlog : Int = ::Socket::SOMAXCONN, mode : Int = 0o600) : Server
        new(path, framed, authenticate, backlog, mode)
      end

      protected def initialize(@path : String, @framed : Bool, @authenticate : Bool,
                               backlog : Int, mode : Int)
        File.delete?(@path)
        @server = UNIXServer.new(@path, backlog: backlog.to_i32)
        File.chmod(@path, mode.to_i32)
        @closed = false
      end

      def accept(timeout : Time::Span? = nil) : Socket
        accept?(timeout) || raise TimeoutError.new("accept timed out")
      end

      def accept?(timeout : Time::Span? = nil) : Socket?
        raise ClosedError.new if @closed
        @server.read_timeout = Deadline.new(timeout).remaining
        socket = @server.accept?
        return nil unless socket

        socket.sync = false
        mailbox = Socket.new(socket, @path, @framed)
        if @authenticate && mailbox.peer_credentials.uid != LibC.getuid
          mailbox.close
          raise PermissionDenied.new("peer does not belong to the current user")
        end
        mailbox
      rescue IO::TimeoutError
        nil
      end

      def each(timeout : Time::Span? = nil, & : Socket ->) : Nil
        loop do
          socket = accept?(timeout)
          break unless socket
          yield socket
        end
      rescue ClosedError
      end

      def close : Nil
        return if @closed
        @closed = true
        @server.close
        File.delete?(@path)
      rescue IO::Error
      end

      def finalize
        close rescue nil
      end
    end
  end
end
