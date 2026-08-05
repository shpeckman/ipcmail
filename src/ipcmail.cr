# src/ipcmail.cr
require "socket"
require "sync"
require "uri"

require "./ipcmail/lib_ipc"
require "./ipcmail/errors"
require "./ipcmail/types"
require "./ipcmail/layout"
require "./ipcmail/segment"
require "./ipcmail/buffer"
require "./ipcmail/signal"
require "./ipcmail/framing"
require "./ipcmail/mailbox"
require "./ipcmail/shared_memory"
require "./ipcmail/bus"
require "./ipcmail/stream"
require "./ipcmail/socket"
require "./ipcmail/pipe"
require "./ipcmail/pty"
require "./ipcmail/address"
require "./ipcmail/monitor"

module IPCMail
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify }}

  def self.create(uri : String, *, capacity : Int? = nil, block_size : Int? = nil,
                  blocks : Int? = nil, trace : Int? = nil, subscribers : Int? = nil,
                  overflow : Overflow? = nil, mode : Int? = nil, framed : Bool? = nil,
                  direction : Pipe::Direction? = nil, raw : Bool? = nil, rows : Int? = nil,
                  columns : Int? = nil, timeout : Time::Span? = 5.seconds) : Mailbox
    build(uri, capacity: capacity, block_size: block_size, blocks: blocks, trace: trace,
      subscribers: subscribers, overflow: overflow, mode: mode, framed: framed,
      direction: direction, raw: raw, rows: rows, columns: columns, timeout: timeout)
  end

  def self.create(uri : String, **options, &)
    mailbox = build(uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  def self.create(kind : SharedMemory.class, uri : String, **options) : SharedMemory
    expect(uri, "shm", "create")
    build(uri, **options).as(SharedMemory)
  end

  def self.create(kind : Bus.class, uri : String, **options) : Bus
    expect(uri, "bus", "create")
    build(uri, **options).as(Bus)
  end

  def self.create(kind : Pipe.class, uri : String, **options) : Pipe
    expect(uri, "fifo", "create")
    build(uri, **options).as(Pipe)
  end

  def self.create(kind : Pty.class, uri : String, **options) : Pty
    expect(uri, "pty", "create")
    build(uri, **options).as(Pty)
  end

  def self.create(kind : T.class, uri : String, **options, &) forall T
    mailbox = create(kind, uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  private def self.build(uri : String, *, capacity : Int? = nil, block_size : Int? = nil,
                         blocks : Int? = nil, trace : Int? = nil, subscribers : Int? = nil,
                         overflow : Overflow? = nil, mode : Int? = nil, framed : Bool? = nil,
                         direction : Pipe::Direction | Symbol | Nil = nil, raw : Bool? = nil,
                         rows : Int? = nil, columns : Int? = nil,
                         timeout : Time::Span? = 5.seconds) : Mailbox
    address  = Address.parse(uri)
    settings = config(address, capacity, block_size, blocks, trace, subscribers, overflow, mode)

    case address.scheme
    when "shm"
      SharedMemory.create(address.target, settings)
    when "bus"
      Bus.create(address.target, settings)
    when "fifo"
      Pipe.fifo(address.target, direction(address, direction), framed: framed?(address, framed),
        timeout: timeout, mode: settings.mode)
    when "pty"
      unless address.target.empty?
        raise SchemeError.new("pty://#{address.target} already exists, attach to it with IPCMail.open(#{uri.inspect})")
      end
      Pty.open(framed: framed?(address, framed, false), raw: raw?(address, raw, true),
        rows: rows || address.rows?, columns: columns || address.columns?)
    else
      raise SchemeError.new("#{address.scheme}:// endpoints are created with IPCMail.listen(#{uri.inspect})")
    end
  end

  def self.open(uri : String, *, overflow : Overflow? = nil, mode : Int? = nil,
                framed : Bool? = nil, direction : Pipe::Direction? = nil, raw : Bool? = nil,
                rows : Int? = nil, columns : Int? = nil,
                timeout : Time::Span? = 5.seconds) : Mailbox
    attach(uri, overflow: overflow, mode: mode, framed: framed, direction: direction,
      raw: raw, rows: rows, columns: columns, timeout: timeout)
  end

  def self.open(uri : String, **options, &)
    mailbox = attach(uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  def self.open(kind : SharedMemory.class, uri : String, **options) : SharedMemory
    expect(uri, "shm", "open")
    attach(uri, **options).as(SharedMemory)
  end

  def self.open(kind : Bus.class, uri : String, **options) : Bus
    expect(uri, "bus", "open")
    attach(uri, **options).as(Bus)
  end

  def self.open(kind : Socket.class, uri : String, **options) : Socket
    expect(uri, "unix", "open")
    attach(uri, **options).as(Socket)
  end

  def self.open(kind : Pipe.class, uri : String, **options) : Pipe
    expect(uri, "fifo", "open")
    attach(uri, **options).as(Pipe)
  end

  def self.open(kind : Pty.class, uri : String, **options) : Pty
    expect(uri, "pty", "open")
    attach(uri, **options).as(Pty)
  end

  def self.open(kind : T.class, uri : String, **options, &) forall T
    mailbox = open(kind, uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  private def self.attach(uri : String, *, overflow : Overflow? = nil, mode : Int? = nil,
                          framed : Bool? = nil, direction : Pipe::Direction | Symbol | Nil = nil,
                          raw : Bool? = nil, rows : Int? = nil, columns : Int? = nil,
                          timeout : Time::Span? = 5.seconds) : Mailbox
    address     = Address.parse(uri)
    policy      = overflow || address.overflow? || Overflow::Fail
    permissions = mode || address.mode? || 0o600

    case address.scheme
    when "shm"
      SharedMemory.open(address.target, timeout: timeout, overflow: policy, mode: permissions)
    when "bus"
      Bus.open(address.target, timeout: timeout, overflow: policy, mode: permissions)
    when "unix"
      Socket.connect(address.target, framed: framed?(address, framed), timeout: timeout)
    when "fifo"
      Pipe.fifo(address.target, direction(address, direction), framed: framed?(address, framed),
        timeout: timeout, mode: permissions)
    when "pty"
      if address.target.empty?
        raise SchemeError.new(%(pty:// endpoints are opened by device path, allocate a new one with IPCMail.create("pty://")))
      end
      Pty.attach(address.target, framed: framed?(address, framed, false),
        raw: raw?(address, raw, false), rows: rows || address.rows?,
        columns: columns || address.columns?)
    else
      raise SchemeError.new("unsupported scheme #{address.scheme.inspect}")
    end
  end

  def self.listen(uri : String, *, framed : Bool? = nil, authenticate : Bool? = nil,
                  backlog : Int = ::Socket::SOMAXCONN, mode : Int? = nil) : Socket::Server
    serve(uri, framed: framed, authenticate: authenticate, backlog: backlog, mode: mode)
  end

  def self.listen(uri : String, **options, &)
    server = serve(uri, **options)
    begin
      yield server
    ensure
      server.close
    end
  end

  def self.listen(kind : Socket::Server.class, uri : String, **options) : Socket::Server
    expect(uri, "unix", "listen")
    serve(uri, **options)
  end

  def self.listen(kind : Socket::Server.class, uri : String, **options, &)
    server = listen(kind, uri, **options)
    begin
      yield server
    ensure
      server.close
    end
  end

  private def self.serve(uri : String, *, framed : Bool? = nil, authenticate : Bool? = nil,
                         backlog : Int = ::Socket::SOMAXCONN, mode : Int? = nil) : Socket::Server
    address = Address.parse(uri)
    unless address.scheme == "unix"
      raise SchemeError.new("#{address.scheme}:// endpoints do not listen, create them with IPCMail.create(#{uri.inspect})")
    end

    Socket::Server.listen(address.target, framed: framed?(address, framed),
      authenticate: authenticate.nil? ? (address.boolean?("authenticate") || false) : authenticate,
      backlog: backlog, mode: mode || address.mode? || 0o600)
  end

  def self.monitor(uri : String, timeout : Time::Span? = 5.seconds) : Monitor
    Monitor.open(uri, timeout)
  end

  def self.unlink(uri : String) : Bool
    address = Address.parse(uri)
    case address.scheme
    when "shm", "bus"
      removed = Buffer.unlink(address.target)
      File.delete?(Signal.path_for(address.target, "a"))
      File.delete?(Signal.path_for(address.target, "b"))
      File.delete?(Signal.path_for(address.target, "overflow"))
      LibIPC::MAX_SUBSCRIBERS.times do |slot|
        File.delete?(Signal.path_for(address.target, "sub#{slot}"))
      end
      removed
    when "unix", "fifo"
      File.delete?(address.target)
    else
      raise SchemeError.new("cannot unlink #{address.scheme}:// endpoints")
    end
  end

  private def self.config(address : Address, capacity, block_size, blocks, trace,
                          subscribers, overflow, mode) : Config
    Config.new(
      capacity: capacity || address.integer?("capacity", "msgs") || 32,
      block_size: block_size || address.integer?("block_size", "bsize") || 256,
      blocks: blocks || address.integer?("blocks", "bcount") || 64,
      trace: trace || address.integer?("trace") || 0,
      subscribers: subscribers || address.integer?("subscribers", "subs") || LibIPC::MAX_SUBSCRIBERS,
      overflow: overflow || address.overflow? || Overflow::Fail,
      mode: mode || address.mode? || 0o600
    )
  end

  private def self.framed?(address : Address, override : Bool?, default : Bool = true) : Bool
    return override unless override.nil?
    framed = address.framed?
    framed.nil? ? default : framed
  end

  private def self.raw?(address : Address, override : Bool?, default : Bool) : Bool
    return override unless override.nil?
    raw = address.raw?
    raw.nil? ? default : raw
  end

  private def self.direction(address : Address, override : Pipe::Direction | Symbol | Nil) : Pipe::Direction
    resolved = override.is_a?(Symbol) ? Pipe::Direction.parse(override.to_s) : override
    resolved || address.direction? ||
      raise ArgumentError.new("fifo:// endpoints need a direction, pass direction: :read / :write or ?direction=read")
  end

  private def self.expect(uri : String, scheme : String, verb : String) : Nil
    actual = Address.parse(uri).scheme
    return if actual == scheme
    raise SchemeError.new("IPCMail.#{verb} expected a #{scheme}:// endpoint but got #{actual}://")
  end
end