# spec/address_spec.cr
require "./spec_helper"

describe IPCMail::Address do
  it "parses the scheme and target" do
    address = IPCMail::Address.parse("shm://jobs")
    address.scheme.should eq("shm")
    address.target.should eq("jobs")
  end

  it "reads integer parameters and aliases" do
    address = IPCMail::Address.parse("shm://q?capacity=64")
    address.integer?("capacity", "msgs").should eq(64)
    aliased = IPCMail::Address.parse("shm://q?msgs=16")
    aliased.integer?("capacity", "msgs").should eq(16)
  end

  it "reads octal file modes" do
    IPCMail::Address.parse("shm://q?mode=644").mode?.should eq(0o644)
    IPCMail::Address.parse("shm://q?permissions=600").mode?.should eq(0o600)
  end

  it "reads overflow policies" do
    IPCMail::Address.parse("shm://q?overflow=block").overflow?.should eq(IPCMail::Overflow::Block)
    IPCMail::Address.parse("shm://q").overflow?.should be_nil
  end

  it "reads booleans and framing" do
    IPCMail::Address.parse("unix:///s?framed=0").framed?.should be_false
    IPCMail::Address.parse("unix:///s?framed=1").framed?.should be_true
    IPCMail::Address.parse("unix:///s?stream=1").framed?.should be_false
    IPCMail::Address.parse("unix:///s?stream=0").framed?.should be_true
    IPCMail::Address.parse("unix:///s").framed?.should be_nil
  end

  it "reads fifo direction from param or flag" do
    IPCMail::Address.parse("fifo:///p?direction=write").direction?.should eq(IPCMail::Pipe::Direction::Write)
    IPCMail::Address.parse("fifo:///p?read=1").direction?.should eq(IPCMail::Pipe::Direction::Read)
  end

  it "allows an anonymous pty target" do
    address = IPCMail::Address.parse("pty://")
    address.scheme.should eq("pty")
    address.target.should be_empty
  end

  it "parses a pty device path" do
    IPCMail::Address.parse("pty:///dev/pts/3").target.should eq("/dev/pts/3")
  end

  it "reads pty geometry and raw mode" do
    address = IPCMail::Address.parse("pty://?rows=30&cols=100&raw=1")
    address.rows?.should eq(30)
    address.columns?.should eq(100)
    address.raw?.should be_true
    IPCMail::Address.parse("pty://?columns=80").columns?.should eq(80)
    IPCMail::Address.parse("pty://").raw?.should be_nil
  end

  it "rejects an unknown scheme" do
    expect_raises(ArgumentError, /unsupported scheme/) { IPCMail::Address.parse("tcp://host") }
  end

  it "rejects a missing target" do
    expect_raises(ArgumentError, /no target/) { IPCMail::Address.parse("shm://") }
  end

  it "rejects a non-integer parameter" do
    expect_raises(ArgumentError, /not an integer/) do
      IPCMail::Address.parse("shm://q?capacity=lots").integer?("capacity")
    end
  end
end