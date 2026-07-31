# spec/shared_memory_spec.cr
require "./spec_helper"

private def with_pair(**options, &)
  name = SpecSupport.unique("shm")
  creator = IPCMail::SharedMemory.create(name, **options)
  peer = IPCMail::SharedMemory.open(name, timeout: 2.seconds, overflow: creator.overflow)
  begin
    yield creator, peer
  ensure
    peer.close
    creator.close
  end
end

describe IPCMail::SharedMemory do
  it "moves messages between both endpoints" do
    with_pair do |creator, peer|
      creator.send("ping", type: 7)
      message = peer.receive(2.seconds)
      message.text.should eq("ping")
      message.type.should eq(7_u32)
      message.priority.should eq(IPCMail::Priority::Normal)

      peer.send("pong", type: 8, priority: :high)
      answer = creator.receive(2.seconds)
      answer.text.should eq("pong")
      answer.priority.should eq(IPCMail::Priority::High)
    end
  end

  it "drains high priority messages first" do
    with_pair do |creator, peer|
      creator.send("normal-1")
      creator.send("normal-2")
      creator.send("urgent", priority: :high)

      peer.receive(2.seconds).text.should eq("urgent")
      peer.receive(2.seconds).text.should eq("normal-1")
      peer.receive(2.seconds).text.should eq("normal-2")
    end
  end

  it "sends and receives without copying the payload" do
    with_pair(block_size: 64) do |creator, peer|
      creator.send(11, type: 3, priority: :high) do |slice|
        slice.copy_from("zero copies".to_slice)
      end

      seen = nil
      peer.receive(2.seconds) do |view|
        view.text.should eq("zero copies")
        view.type.should eq(3_u32)
        view.priority.should eq(IPCMail::Priority::High)
        seen = view.size
      end
      seen.should eq(11)
    end
  end

  it "returns the block to the pool once the message is consumed" do
    with_pair(blocks: 2) do |creator, peer|
      4.times do |index|
        creator.send("message #{index}")
        peer.receive(2.seconds).text.should eq("message #{index}")
      end
      creator.segment.blocks_in_use.should eq(0_u32)
    end
  end

  it "times out on an empty mailbox" do
    with_pair do |creator, peer|
      started = Time.instant
      peer.receive?(120.milliseconds).should be_nil
      (Time.instant - started).should be >= 100.milliseconds
      expect_raises(IPCMail::TimeoutError) { peer.receive(50.milliseconds) }
    end
  end

  it "rejects payloads larger than a block" do
    with_pair(block_size: 16) do |creator, peer|
      expect_raises(IPCMail::MessageTooLarge) { creator.send("x" * 17) }
    end
  end

  it "fails fast when every block is taken" do
    with_pair(blocks: 2, capacity: 8) do |creator, peer|
      creator.send("one")
      creator.send("two")
      expect_raises(IPCMail::FullError) { creator.send("three") }
    end
  end

  it "waits for a free block when the overflow policy blocks" do
    with_pair(blocks: 1, capacity: 4, overflow: IPCMail::Overflow::Block) do |creator, peer|
      creator.send("first")

      spawn do
        sleep 60.milliseconds
        peer.receive(2.seconds)
      end

      creator.send("second", timeout: 2.seconds)
      peer.receive(2.seconds).text.should eq("second")
    end
  end

  it "spills to the overflow fifo when no block is available" do
    with_pair(blocks: 1, capacity: 4, overflow: IPCMail::Overflow::Spill) do |creator, peer|
      creator.send("in band")
      creator.send("out of band", type: 42, priority: :high)

      spilled = creator.overflow_receive?(1.second).should_not be_nil
      spilled.text.should eq("out of band")
      spilled.type.should eq(42_u32)
      spilled.priority.should eq(IPCMail::Priority::High)
    end
  end

  it "blocks the sender when the ring is full and wakes it up again" do
    with_pair(capacity: 3, blocks: 8) do |creator, peer|
      creator.send("a")
      creator.send("b")

      spawn do
        sleep 60.milliseconds
        peer.receive(2.seconds)
      end

      creator.send("c", timeout: 2.seconds)
      peer.receive(2.seconds)
      peer.receive(2.seconds).text.should eq("c")
    end
  end

  it "reports a timeout instead of blocking forever on a full ring" do
    with_pair(capacity: 3, blocks: 8) do |creator, peer|
      creator.send("a")
      creator.send("b")
      expect_raises(IPCMail::TimeoutError) { creator.send("c", timeout: 80.milliseconds) }
    end
  end

  it "records a trace of every transfer" do
    with_pair(trace: 32) do |creator, peer|
      creator.send("traced", type: 5, priority: :high)
      peer.receive(2.seconds)

      records = creator.trace
      records.size.should eq(2)
      records[0].event.should eq(IPCMail::Event::Send)
      records[0].type.should eq(5_u32)
      records[0].size.should eq(6_u32)
      records[0].priority.should eq(IPCMail::Priority::High)
      records[1].event.should eq(IPCMail::Event::Receive)
      creator.trace.should be_empty
    end
  end

  it "keeps two fibers streaming through the same segment" do
    with_pair(capacity: 4, blocks: 4) do |creator, peer|
      total = 64
      received = [] of String

      consumer = spawn do
        total.times { received << peer.receive(5.seconds).text }
      end

      total.times { |index| creator.send("m#{index}", timeout: 5.seconds) }
      while received.size < total
        sleep 1.millisecond
      end

      received.size.should eq(total)
      received.first.should eq("m0")
      received.last.should eq("m#{total - 1}")
    end
  end

  it "survives several fibers sharing the same endpoint" do
    with_pair(capacity: 4, blocks: 4, overflow: IPCMail::Overflow::Block) do |creator, peer|
      senders = 4
      each = 16
      total = senders * each
      received = 0

      senders.times do |sender|
        spawn do
          each.times { |index| creator.send("s#{sender}-#{index}", timeout: 10.seconds) }
        end
      end

      2.times do
        spawn do
          loop do
            break unless peer.receive?(10.seconds)
            received += 1
          end
        end
      end

      deadline = Time.instant + 20.seconds
      while received < total && Time.instant < deadline
        sleep 1.millisecond
      end

      received.should eq(total)
      creator.segment.blocks_in_use.should eq(0_u32)
    end
  end

  it "talks to another process" do
    name = SpecSupport.unique("shm_worker")
    mailbox = IPCMail::SharedMemory.create(name, block_size: 128)
    process = SpecSupport.worker("echo", name)

    begin
      mailbox.send("hello from the parent", type: 1)
      answer = mailbox.receive(10.seconds)
      answer.text.should eq("HELLO FROM THE PARENT")
      answer.type.should eq(2_u32)
      process.wait.success?.should be_true
    ensure
      mailbox.close
    end
  end

  it "reclaims blocks leaked by a process that died" do
    name = SpecSupport.unique("shm_leak")
    mailbox = IPCMail::SharedMemory.create(name, blocks: 1, capacity: 4)

    begin
      SpecSupport.worker("hoard", name).wait
      mailbox.segment.blocks_in_use.should eq(1_u32)
      expect_raises(IPCMail::FullError) { mailbox.send("blocked") }

      mailbox.segment.sweep
      mailbox.segment.blocks_in_use.should eq(0_u32)
      mailbox.send("recovered")
    ensure
      mailbox.close
    end
  end

  it "steals the segment lock from a process that died while holding it" do
    name = SpecSupport.unique("shm_lock")
    mailbox = IPCMail::SharedMemory.create(name, blocks: 4, capacity: 4)

    begin
      SpecSupport.worker("deadlock", name).wait
      started = Time.instant
      mailbox.send("after the crash")
      (Time.instant - started).should be < 5.seconds
      mailbox.segment.depth(0).should eq(1_u32)
    ensure
      mailbox.close
    end
  end
end