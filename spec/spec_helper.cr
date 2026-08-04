# spec/spec_helper.cr
require "spec"
require "../src/ipcmail"

module SpecSupport
  @@counter = Atomic(UInt64).new(0)

  def self.token : String
    "ipcmail-spec-#{Process.pid}-#{@@counter.add(1)}-#{Random::Secure.hex(4)}"
  end

  def self.shm_name : String
    token
  end

  def self.socket_path : String
    File.join(Dir.tempdir, "#{token}.sock")
  end

  def self.fifo_path : String
    File.join(Dir.tempdir, "#{token}.fifo")
  end

  @@peer_binary : String? = nil
  @@peer_lock = Mutex.new

  def self.peer_binary : String
    @@peer_lock.synchronize do
      binary = @@peer_binary
      return binary if binary

      source = File.join(__DIR__, "support", "peer.cr")
      target = File.join(Dir.tempdir, "ipcmail-peer-#{Process.pid}")
      status = Process.run("crystal", ["build", source, "-o", target],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      raise "failed to build spec peer helper" unless status.success?
      at_exit { File.delete?(target) }
      @@peer_binary = target
    end
  end

  def self.spawn_peer(command : String, name : String, args : Array(String) = [] of String) : Process
    process = Process.new(peer_binary, [command, name] + args,
      output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
    line = process.output.gets
    unless line == "ready"
      process.terminate rescue nil
      raise "peer #{command} did not become ready (got #{line.inspect})"
    end
    process
  end

  def self.kill_peer(process : Process) : Nil
    process.signal(Signal::KILL) rescue nil
    process.wait
  end
end

def with_shm(capacity : Int = 32, block_size : Int = 256, blocks : Int = 64,
             trace : Int = 0, overflow : IPCMail::Overflow = :fail, &)
  name = SpecSupport.shm_name
  producer = IPCMail::SharedMemory.create(name, capacity: capacity, block_size: block_size,
    blocks: blocks, trace: trace, overflow: overflow)
  consumer = IPCMail::SharedMemory.open(name, overflow: overflow)
  begin
    yield producer, consumer
  ensure
    consumer.close rescue nil
    producer.close rescue nil
  end
end
