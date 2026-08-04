# spec/pipe_spec.cr
require "./spec_helper"

describe IPCMail::Pipe do
  it "round-trips a framed anonymous pair" do
    left, right = IPCMail::Pipe.pair
    begin
      left.send("through", type: 4)
      message = right.receive
      message.text.should eq("through")
      message.type.should eq(4_u32)
    ensure
      left.close
      right.close
    end
  end

  it "is directional over a named fifo" do
    path = SpecSupport.fifo_path
    begin
      reader = nil.as(IPCMail::Pipe?)
      spawn { reader = IPCMail::Pipe.fifo(path, :read, timeout: 2.seconds) }
      sleep 20.milliseconds
      writer = IPCMail::Pipe.fifo(path, :write, timeout: 2.seconds)

      writer.send("fifo-message")
      sleep 20.milliseconds
      reader.not_nil!.receive.text.should eq("fifo-message")

      writer.writable?.should be_true
      writer.readable?.should be_false
      reader.not_nil!.readable?.should be_true

      writer.close
      reader.not_nil!.close
    ensure
      File.delete?(path)
    end
  end

  it "reports send-only and receive-only errors" do
    path = SpecSupport.fifo_path
    begin
      reader = nil.as(IPCMail::Pipe?)
      spawn { reader = IPCMail::Pipe.fifo(path, :read, timeout: 2.seconds) }
      sleep 20.milliseconds
      writer = IPCMail::Pipe.fifo(path, :write, timeout: 2.seconds)

      expect_raises(IPCMail::Error, /send only/) { writer.receive }
      r = reader.not_nil!
      expect_raises(IPCMail::Error, /receive only/) { r.send("x") }

      writer.close
      r.close
    ensure
      File.delete?(path)
    end
  end
end

describe IPCMail::Monitor do
  it "reports segment statistics" do
    name = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name, capacity: 8, blocks: 16)
    monitor  = IPCMail.monitor("shm://#{name}")
    begin
      producer.send("watched")
      stats = monitor.stats
      stats.name.should eq(name)
      stats.kind.should eq(IPCMail::Kind::PointToPoint)
      stats.capacity.should eq(8_u32)
      stats.block_count.should eq(16_u32)
      stats.blocks_in_use.should eq(1_u32)
      stats.usage.should be > 0.0
    ensure
      monitor.close
      producer.close
    end
  end

  it "reports subscriber rings for a bus" do
    name = SpecSupport.shm_name
    publisher  = IPCMail::Bus.create(name, subscribers: 4)
    subscriber = IPCMail::Bus.open(name)
    monitor    = IPCMail.monitor("bus://#{name}")
    begin
      subscriber.subscribe
      publisher.publish("fanned")
      stats = monitor.stats
      stats.kind.should eq(IPCMail::Kind::Bus)
      stats.subscribers.should eq(1_u32)
      stats.rings.size.should eq(1)
      subscriber.receive
    ensure
      monitor.close
      subscriber.close
      publisher.close
    end
  end
end