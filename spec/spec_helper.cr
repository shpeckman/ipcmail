# spec/spec_helper.cr
require "spec"
require "../src/ipcmail"

lib LibSpec
  fun _exit(status : LibC::Int) : NoReturn
  fun pthread_self : LibC::ULong
end

module SpecSupport
  extend self

  def thread_id : UInt64
    LibSpec.pthread_self.to_u64
  end

  def unique(prefix : String) : String
    "/ipcmail_#{prefix}_#{Process.pid}_#{Random.rand(0xffffff).to_s(16)}"
  end

  def temp_path(prefix : String) : String
    File.join(Dir.tempdir, "ipcmail_#{prefix}_#{Process.pid}_#{Random.rand(0xffffff).to_s(16)}")
  end

  def worker(name : String, target : String, extra : Hash(String, String) = {} of String => String) : Process
    environment = {"IPCMAIL_WORKER" => name, "IPCMAIL_TARGET" => target}
    extra.each { |key, value| environment[key] = value }
    Process.new(PROGRAM_NAME, env: environment, output: :inherit, error: :inherit)
  end

  def run_worker(name : String) : NoReturn
    target = ENV["IPCMAIL_TARGET"]

    case name
    when "echo"
      mailbox = IPCMail::SharedMemory.open(target, timeout: 10.seconds)
      message = mailbox.receive(5.seconds)
      mailbox.send(message.text.upcase, type: message.type + 1, priority: message.priority)
      mailbox.close
    when "subscriber"
      bus = IPCMail::Bus.open(target, timeout: 10.seconds)
      bus.subscribe(100)
      message = bus.receive(5.seconds)
      bus.publish("ack:#{message.text}", type: 200)
      bus.close
    when "buffer"
      mailbox = IPCMail::SharedMemory.open(target, timeout: 10.seconds)
      message = mailbox.receive(5.seconds)
      IPCMail::Buffer.open(message.text, read_only: true) do |buffer|
        mailbox.send(buffer.to_slice.sum(&.to_u64).to_s, type: 2)
      end
      mailbox.close
    when "hoard"
      mailbox = IPCMail::SharedMemory.open(target, timeout: 10.seconds)
      mailbox.send(4) { |slice| slice.copy_from("halt".to_slice); LibSpec._exit(0) }
    when "deadlock"
      mailbox = IPCMail::SharedMemory.open(target, timeout: 10.seconds)
      mailbox.segment.lock
      LibSpec._exit(0)
    else
      STDERR.puts "unknown worker #{name}"
      LibSpec._exit(2)
    end

    LibSpec._exit(0)
  end
end

if worker = ENV["IPCMAIL_WORKER"]?
  SpecSupport.run_worker(worker)
end