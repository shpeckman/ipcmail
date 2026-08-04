# spec/config_spec.cr
require "./spec_helper"

describe IPCMail::Config do
  it "accepts sensible defaults" do
    config = IPCMail::Config.new
    config.capacity.should eq(32_u32)
    config.block_size.should eq(256_u32)
    config.blocks.should eq(64_u32)
    config.overflow.should eq(IPCMail::Overflow::Fail)
    config.mode.should eq(0o600_u32)
  end

  it "rejects a capacity below two" do
    expect_raises(ArgumentError, /capacity/) { IPCMail::Config.new(capacity: 1) }
  end

  it "rejects a non-positive block size" do
    expect_raises(ArgumentError, /block_size/) { IPCMail::Config.new(block_size: 0) }
  end

  it "rejects a non-positive block count" do
    expect_raises(ArgumentError, /blocks/) { IPCMail::Config.new(blocks: 0) }
  end

  it "rejects fewer than one subscriber" do
    expect_raises(ArgumentError, /subscribers/) { IPCMail::Config.new(subscribers: 0) }
  end

  it "rejects more subscribers than the maximum" do
    expect_raises(ArgumentError, /subscribers/) do
      IPCMail::Config.new(subscribers: LibIPC::MAX_SUBSCRIBERS + 1)
    end
  end
end

describe IPCMail::Deadline do
  it "reports infinite when no timeout is given" do
    deadline = IPCMail::Deadline.new(nil)
    deadline.infinite?.should be_true
    deadline.expired?.should be_false
    deadline.remaining.should be_nil
  end

  it "expires after the span elapses" do
    deadline = IPCMail::Deadline.new(1.millisecond)
    deadline.infinite?.should be_false
    sleep 5.milliseconds
    deadline.expired?.should be_true
    deadline.remaining.should eq(Time::Span.zero)
  end

  it "caps the remaining span" do
    IPCMail::Deadline.new(nil).remaining(50.milliseconds).should eq(50.milliseconds)
    span = IPCMail::Deadline.new(10.milliseconds).remaining(1.second)
    span.should be <= 10.milliseconds
  end
end

describe IPCMail::Message do
  it "exposes the payload as text and slice" do
    message = IPCMail::Message.new("hello".to_slice, 7_u32, :high)
    message.text.should eq("hello")
    message.type.should eq(7_u32)
    message.priority.should eq(IPCMail::Priority::High)
    message.size.should eq(5)
  end
end

describe IPCMail::View do
  it "copies into an owned message" do
    buffer = "data".to_slice.dup
    view   = IPCMail::View.new(buffer, 1_u32, :normal)
    copy   = view.copy
    buffer[0] = 0_u8
    copy.text.should eq("data")
    copy.type.should eq(1_u32)
  end
end