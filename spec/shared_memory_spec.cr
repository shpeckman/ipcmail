# spec/shared_memory_spec.cr
require "./spec_helper"

describe IPCMail::SharedMemory do
  it "round-trips a message between two endpoints" do
    with_shm do |producer, consumer|
      producer.send("hello")
      consumer.receive.text.should eq("hello")
    end
  end

  it "carries type and priority" do
    with_shm do |producer, consumer|
      producer.send("tagged", type: 42, priority: :high)
      message = consumer.receive
      message.type.should eq(42_u32)
      message.priority.should eq(IPCMail::Priority::High)
    end
  end

  it "is full-duplex" do
    with_shm do |a, b|
      a.send("to-b")
      b.send("to-a")
      b.receive.text.should eq("to-b")
      a.receive.text.should eq("to-a")
    end
  end

  it "delivers high priority before normal priority" do
    with_shm do |producer, consumer|
      producer.send("normal-1", priority: :normal)
      producer.send("high-1", priority: :high)
      producer.send("normal-2", priority: :normal)
      producer.send("high-2", priority: :high)
      consumer.receive.text.should eq("high-1")
      consumer.receive.text.should eq("high-2")
      consumer.receive.text.should eq("normal-1")
      consumer.receive.text.should eq("normal-2")
    end
  end

  it "supports zero-copy block sends" do
    with_shm do |producer, consumer|
      producer.send(4) { |slice| slice.copy_from("copy".to_slice) }
      consumer.receive.text.should eq("copy")
    end
  end

  it "yields a borrowed view on the block form of receive" do
    with_shm do |producer, consumer|
      producer.send("borrow")
      seen = ""
      consumer.receive { |view| seen = view.text }
      seen.should eq("borrow")
    end
  end

  it "reports pending and queued depth" do
    with_shm do |producer, consumer|
      producer.send("one")
      producer.send("two")
      producer.queued.should eq(2_u32)
      consumer.pending.should eq(2_u32)
      consumer.receive
      consumer.pending.should eq(1_u32)
    end
  end

  it "rejects a payload larger than a block" do
    with_shm(block_size: 8) do |producer, _|
      expect_raises(IPCMail::MessageTooLarge) { producer.send(Bytes.new(9)) }
    end
  end

  it "raises FullError under the fail policy with no timeout" do
    with_shm(blocks: 1, overflow: :fail) do |producer, _|
      producer.send("fills")
      expect_raises(IPCMail::FullError) { producer.send("overflows") }
    end
  end

  it "times out under the fail policy with a deadline" do
    with_shm(blocks: 1, overflow: :fail) do |producer, _|
      producer.send("fills")
      expect_raises(IPCMail::TimeoutError) { producer.send("overflows", timeout: 20.milliseconds) }
    end
  end

  it "send? returns false instead of raising on a full mailbox" do
    with_shm(blocks: 1, overflow: :fail) do |producer, _|
      producer.send("fills")
      producer.send?("overflows").should be_false
    end
  end

  it "blocks until a slot frees under the block policy" do
    with_shm(blocks: 1, overflow: :block) do |producer, consumer|
      producer.send("first")
      spawn do
        sleep 20.milliseconds
        consumer.receive
      end
      producer.send("second", timeout: 2.seconds)
      consumer.receive.text.should eq("second")
    end
  end

  it "preserves FIFO order across the ring and spill boundary" do
    with_shm(blocks: 2, overflow: :spill) do |producer, consumer|
      5.times { |i| producer.send("m#{i}") }
      5.times { |i| consumer.receive.text.should eq("m#{i}") }
    end
  end

  it "keeps spilled high priority ordered after the drained ring" do
    with_shm(blocks: 1, overflow: :spill) do |producer, consumer|
      producer.send("ring-normal", priority: :normal)
      producer.send("spilled-high", priority: :high)
      consumer.receive.text.should eq("ring-normal")
      consumer.receive.text.should eq("spilled-high")
    end
  end

  it "surfaces backpressure when the spill channel saturates with a deadline" do
    name = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name, block_size: 60000, blocks: 1, overflow: :spill)
    begin
      big = Bytes.new(59000, 1_u8)
      producer.send(big)
      raised = false
      begin
        8.times { producer.send(big, timeout: 50.milliseconds) }
      rescue IPCMail::TimeoutError
        raised = true
      end
      raised.should be_true
    ensure
      producer.close
    end
  end

  it "records trace entries for spilled sends" do
    with_shm(blocks: 1, overflow: :spill, trace: 16) do |producer, consumer|
      producer.send("ring")
      producer.send("spilled")
      producer.trace.size.should eq(2)
      2.times { consumer.receive }
    end
  end

  it "refuses to create over an existing segment" do
    name = SpecSupport.shm_name
    first = IPCMail::SharedMemory.create(name)
    begin
      expect_raises(IPCMail::Error, /already exists/) { IPCMail::SharedMemory.create(name) }
    ensure
      first.close
    end
  end

  it "waits for the segment to appear when opening with a timeout" do
    name = SpecSupport.shm_name
    opened = nil.as(IPCMail::SharedMemory?)
    fiber = spawn do
      opened = IPCMail::SharedMemory.open(name, timeout: 2.seconds)
    end
    sleep 20.milliseconds
    producer = IPCMail::SharedMemory.create(name)
    producer.send("late")
    sleep 50.milliseconds
    consumer = opened.not_nil!
    consumer.receive.text.should eq("late")
    consumer.close
    producer.close
  end

  it "times out opening a segment that never appears" do
    expect_raises(IPCMail::TimeoutError) do
      IPCMail::SharedMemory.open(SpecSupport.shm_name, timeout: 30.milliseconds)
    end
  end

  it "iterates queued messages with each" do
    with_shm do |producer, consumer|
      producer.send("a")
      producer.send("b")
      collected = [] of String
      consumer.each(timeout: 20.milliseconds) { |m| collected << m.text }
      collected.should eq(["a", "b"])
    end
  end

  it "reports closed after close" do
    name = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name)
    producer.closed?.should be_false
    producer.close
    producer.closed?.should be_true
    expect_raises(IPCMail::ClosedError) { producer.send("x") }
  end
end