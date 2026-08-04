# spec/oob_spec.cr
require "./spec_helper"

describe "IPCMail out-of-band payloads" do
  it "hands a payload larger than the block size across shared memory" do
    with_shm(block_size: 64, blocks: 8) do |producer, consumer|
      payload = Bytes.new(4096) { |i| (i % 251).to_u8 }
      producer.send_large(payload)
      consumer.receive_large.to_slice.should eq(payload)
    end
  end

  it "hands a large string over a unix socket" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      client   = IPCMail::Socket.connect(path)
      accepted = server.accept
      begin
        text = "x" * 200_000
        client.send_large(text)
        accepted.receive_large.text.should eq(text)
      ensure
        accepted.close
        client.close
      end
    ensure
      server.close
    end
  end

  it "leaves ordinary messages untouched by receive_large" do
    with_shm(block_size: 64, blocks: 8) do |producer, consumer|
      producer.send("plain")
      message = consumer.receive_large
      message.text.should eq("plain")
    end
  end

  it "unlinks the backing buffer after the receiver reads it" do
    with_shm(block_size: 64, blocks: 8) do |producer, consumer|
      producer.send_large(Bytes.new(1024, 7_u8))
      message = consumer.receive
      handle  = IPCMail::Handle.decode(message.payload)

      IPCMail::Buffer.open(handle.name, read_only: true, &.to_slice.dup)

      IPCMail::Buffer.unlink(handle.name)
      expect_raises(IPCMail::SystemError) do
        IPCMail::Buffer.open(handle.name, read_only: true)
      end
    end
  end
end

describe "IPCMail::Segment claim cursor" do
  it "keeps claiming correctly after the cursor wraps the block array" do
    name    = SpecSupport.shm_name
    segment = IPCMail::Segment.create(name, :point_to_point, IPCMail::Config.new(blocks: 4))
    begin
      claimed = [] of UInt32
      segment.synchronize do
        4.times { claimed << segment.claim_block.not_nil! }
        segment.claim_block.should be_nil
      end
      claimed.sort.should eq([0_u32, 1_u32, 2_u32, 3_u32])

      segment.synchronize do
        claimed.each { |index| segment.release_block(index) }
        again = [] of UInt32
        4.times { again << segment.claim_block.not_nil! }
        again.sort.should eq([0_u32, 1_u32, 2_u32, 3_u32])
      end
    ensure
      segment.close
      IPCMail.unlink("shm://#{name}")
    end
  end
end
