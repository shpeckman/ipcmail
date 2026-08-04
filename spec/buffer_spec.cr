# spec/buffer_spec.cr
require "./spec_helper"

describe IPCMail::Buffer do
  it "creates, maps, and shares a region by name" do
    name = "/#{SpecSupport.token}"
    creator = IPCMail::Buffer.create(4096, name)
    begin
      creator.size.should eq(4096_i64)
      creator.creator?.should be_true
      creator.to_slice[0] = 123_u8

      opener = IPCMail::Buffer.open(name)
      begin
        opener.creator?.should be_false
        opener.to_slice[0].should eq(123_u8)
      ensure
        opener.close
      end
    ensure
      creator.close
    end
  end

  it "generates a unique name when none is given" do
    buffer = IPCMail::Buffer.create(64)
    begin
      buffer.name.starts_with?("/ipcmail-").should be_true
    ensure
      buffer.close
    end
  end

  it "rejects an invalid name" do
    expect_raises(ArgumentError) { IPCMail::Buffer.create(64, "no-leading-slash") }
    expect_raises(ArgumentError) { IPCMail::Buffer.create(64, "/nested/name") }
  end

  it "rejects a non-positive size" do
    expect_raises(ArgumentError, /size/) { IPCMail::Buffer.create(0) }
  end

  it "enforces read-only mappings" do
    name = "/#{SpecSupport.token}"
    creator = IPCMail::Buffer.create(64, name)
    begin
      reader = IPCMail::Buffer.open(name, read_only: true)
      begin
        reader.read_only?.should be_true
        reader.to_slice.read_only?.should be_true
      ensure
        reader.close
      end
    ensure
      creator.close
    end
  end

  it "times out opening a missing buffer" do
    expect_raises(IPCMail::TimeoutError) do
      IPCMail::Buffer.open("/#{SpecSupport.token}", timeout: 30.milliseconds)
    end
  end

  it "raises after close" do
    buffer = IPCMail::Buffer.create(64)
    buffer.close
    buffer.closed?.should be_true
    expect_raises(IPCMail::ClosedError) { buffer.to_slice }
  end
end