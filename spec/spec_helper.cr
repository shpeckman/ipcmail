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