# src/ipcmail.cr
require "socket"
require "sync"
require "uri"

require "./ipcmail/lib_ipc"
require "./ipcmail/errors"
require "./ipcmail/types"
require "./ipcmail/layout"
require "./ipcmail/segment"
require "./ipcmail/signal"
require "./ipcmail/framing"
require "./ipcmail/mailbox"
require "./ipcmail/shared_memory"
require "./ipcmail/bus"
require "./ipcmail/stream"
require "./ipcmail/socket"
require "./ipcmail/pipe"
require "./ipcmail/address"
require "./ipcmail/monitor"

module IPCMail
  VERSION = "0.1.0"

  def self.create(uri : String, *, capacity : Int? = nil, block_size : Int? = nil,
                  blocks : Int? = nil, trace : Int? = nil, subscribers : Int? = nil,
                  overflow : Overflow? = nil, mode : Int? = nil, framed : Bool? = nil,
                  timeout : Time::Span? = 5.seconds) : Mailbox
    address = Address.parse(uri)
    settings = config(address, capacity, block_size, blocks, trace, subscribers, overflow, mode)

    case address.scheme
    when "shm"
      SharedMemory.create(address.target, settings)
    when "bus"
      Bus.create(address.target, settings)
    when "fifo"
      Pipe.fifo(address.target, direction(address), framed: framed?(address, framed),
        timeout: timeout, mode: settings.mode)
    else
      raise ArgumentError.new("#{address.scheme}:// endpoints are created with IPCMail.listen")
    end
  end

  def self.create(uri : String, **options, &)
    mailbox = create(uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  def self.open(uri : String, *, overflow : Overflow? = nil, mode : Int? = nil,
                framed : Bool? = nil, timeout : Time::Span? = 5.seconds) : Mailbox
    address = Address.parse(uri)
    policy = overflow || address.overflow? || Overflow::Fail
    permissions = mode || address.mode? || 0o600

    case address.scheme
    when "shm"
      SharedMemory.open(address.target, timeout: timeout, overflow: policy, mode: permissions)
    when "bus"
      Bus.open(address.target, timeout: timeout, overflow: policy, mode: permissions)
    when "unix"
      Socket.connect(address.target, framed: framed?(address, framed), timeout: timeout)
    when "fifo"
      Pipe.fifo(address.target, direction(address), framed: framed?(address, framed),
        timeout: timeout, mode: permissions)
    else
      raise ArgumentError.new("unsupported scheme #{address.scheme.inspect}")
    end
  end

  def self.open(uri : String, **options, &)
    mailbox = open(uri, **options)
    begin
      yield mailbox
    ensure
      mailbox.close
    end
  end

  def self.listen(uri : String, *, framed : Bool? = nil, authenticate : Bool? = nil,
                  backlog : Int = ::Socket::SOMAXCONN, mode : Int? = nil) : Socket::Server
    address = Address.parse(uri)
    unless address.scheme == "unix"
      raise ArgumentError.new("#{address.scheme}:// endpoints do not listen, use IPCMail.create")
    end

    Socket::Server.listen(address.target, framed: framed?(address, framed),
      authenticate: authenticate.nil? ? (address.boolean?("authenticate") || false) : authenticate,
      backlog: backlog, mode: mode || address.mode? || 0o600)
  end

  def self.listen(uri : String, **options, &)
    server = listen(uri, **options)
    begin
      yield server
    ensure
      server.close
    end
  end

  def self.monitor(uri : String, timeout : Time::Span? = 5.seconds) : Monitor
    Monitor.open(uri, timeout)
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

  private def self.framed?(address : Address, override : Bool?) : Bool
    return override unless override.nil?
    framed = address.framed?
    framed.nil? ? true : framed
  end

  private def self.direction(address : Address) : Pipe::Direction
    address.direction? || raise ArgumentError.new("fifo:// endpoints need ?direction=read or ?direction=write")
  end
end