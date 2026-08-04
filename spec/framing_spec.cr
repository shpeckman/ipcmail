# spec/framing_spec.cr
require "./spec_helper"

describe IPCMail::Framing do
  it "round-trips a payload through an IO" do
    io = IO::Memory.new
    IPCMail::Framing.write(io, "payload".to_slice, 9_u32, IPCMail::Priority::High)
    io.rewind
    message = IPCMail::Framing.read(io, 1 << 20)
    message.text.should eq("payload")
    message.type.should eq(9_u32)
    message.priority.should eq(IPCMail::Priority::High)
  end

  it "round-trips an empty payload" do
    io = IO::Memory.new
    IPCMail::Framing.write(io, Bytes.empty, 0_u32, IPCMail::Priority::Normal)
    io.rewind
    message = IPCMail::Framing.read(io, 1 << 20)
    message.size.should eq(0)
  end

  it "rejects a frame larger than the limit" do
    io = IO::Memory.new
    IPCMail::Framing.write(io, Bytes.new(100), 0_u32, IPCMail::Priority::Normal)
    io.rewind
    expect_raises(IPCMail::MessageTooLarge) { IPCMail::Framing.read(io, 50) }
  end
end