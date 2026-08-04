# spec/recovery_spec.cr
require "./spec_helper"

describe "IPCMail crash recovery" do
  it "steals the lock from a process that died holding it" do
    name    = SpecSupport.shm_name
    segment = IPCMail::Segment.create(name, :point_to_point, IPCMail::Config.new(blocks: 8))
    begin
      peer = SpecSupport.spawn_peer("lock-and-die", name)
      SpecSupport.kill_peer(peer)

      acquired = false
      segment.synchronize { acquired = true }
      acquired.should be_true
      segment.owner_pid.should eq(0_u32)
    ensure
      segment.close
      IPCMail.unlink("shm://#{name}")
    end
  end

  it "clears the damaged flag and bumps the generation after recovery" do
    name    = SpecSupport.shm_name
    segment = IPCMail::Segment.create(name, :point_to_point, IPCMail::Config.new(blocks: 8))
    begin
      before = segment.generation

      peer = SpecSupport.spawn_peer("lock-and-die", name)
      SpecSupport.kill_peer(peer)

      segment.synchronize { }
      segment.damaged?.should be_false
      segment.generation.should be > before
    ensure
      segment.close
      IPCMail.unlink("shm://#{name}")
    end
  end

  it "reclaims blocks owned by a dead process" do
    name    = SpecSupport.shm_name
    segment = IPCMail::Segment.create(name, :point_to_point, IPCMail::Config.new(blocks: 8))
    begin
      peer = SpecSupport.spawn_peer("claim-and-die", name, ["5"])
      segment.synchronize { segment.blocks_in_use.should be >= 5_u32 }
      SpecSupport.kill_peer(peer)

      segment.sweep
      segment.synchronize { segment.blocks_in_use.should eq(0_u32) }
    ensure
      segment.close
      IPCMail.unlink("shm://#{name}")
    end
  end

  it "keeps a segment usable after a peer crash mid-lock" do
    name     = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name, blocks: 8)
    begin
      peer = SpecSupport.spawn_peer("lock-and-die", name)
      SpecSupport.kill_peer(peer)

      consumer = IPCMail::SharedMemory.open(name)
      begin
        producer.send("after-crash")
        consumer.receive.text.should eq("after-crash")
      ensure
        consumer.close
      end
    ensure
      producer.close
      IPCMail.unlink("shm://#{name}")
    end
  end
end

describe "IPCMail point-to-point endpoints" do
  it "rejects a third live endpoint on a segment" do
    name     = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name, blocks: 8)
    consumer = IPCMail::SharedMemory.open(name)
    begin
      expect_raises(IPCMail::Error, /two live/) do
        IPCMail::SharedMemory.open(name)
      end
    ensure
      consumer.close
      producer.close
      IPCMail.unlink("shm://#{name}")
    end
  end

  it "frees an endpoint slot when a peer dies so a replacement can attach" do
    name     = SpecSupport.shm_name
    producer = IPCMail::SharedMemory.create(name, blocks: 8)
    begin
      peer = SpecSupport.spawn_peer("endpoint-and-die", name)
      SpecSupport.kill_peer(peer)

      replacement = IPCMail::SharedMemory.open(name)
      begin
        producer.send("hello")
        replacement.receive.text.should eq("hello")
      ensure
        replacement.close
      end
    ensure
      producer.close
      IPCMail.unlink("shm://#{name}")
    end
  end
end

describe "IPCMail.unlink" do
  it "removes shared memory and signal artifacts" do
    name = SpecSupport.shm_name
    IPCMail::SharedMemory.create(name, blocks: 8).close
    IPCMail.unlink("shm://#{name}")

    expect_raises(IPCMail::TimeoutError) do
      IPCMail::SharedMemory.open(name, timeout: 100.milliseconds)
    end
  end
end
