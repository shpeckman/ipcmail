# spec/bus_spec.cr
require "./spec_helper"

private def with_bus(subscribers : Int = 16, blocks : Int = 64, &)
  name = SpecSupport.shm_name
  publisher = IPCMail::Bus.create(name, subscribers: subscribers, blocks: blocks)
  begin
    yield name, publisher
  ensure
    publisher.close rescue nil
  end
end

describe IPCMail::Bus do
  it "fans a message out to every subscriber" do
    with_bus do |name, publisher|
      a = IPCMail::Bus.open(name)
      b = IPCMail::Bus.open(name)
      a.subscribe
      b.subscribe

      reached = publisher.publish("event")
      reached.should eq(2)
      a.receive.text.should eq("event")
      b.receive.text.should eq("event")

      a.close
      b.close
    end
  end

  it "filters by message type" do
    with_bus do |name, publisher|
      everything = IPCMail::Bus.open(name)
      filtered   = IPCMail::Bus.open(name)
      everything.subscribe
      filtered.subscribe(1, 2)

      publisher.publish("typed", type: 2).should eq(2)
      publisher.publish("other", type: 9).should eq(1)

      everything.receive.text.should eq("typed")
      everything.receive.text.should eq("other")
      filtered.receive.text.should eq("typed")
      filtered.pending.should eq(0_u32)

      everything.close
      filtered.close
    end
  end

  it "returns zero when no subscriber matches" do
    with_bus do |name, publisher|
      subscriber = IPCMail::Bus.open(name)
      subscriber.subscribe(5)
      publisher.publish("nobody", type: 1).should eq(0)
      subscriber.close
    end
  end

  it "reports subscription state" do
    with_bus do |name, _|
      subscriber = IPCMail::Bus.open(name)
      subscriber.subscribed?.should be_false
      subscriber.subscribe
      subscriber.subscribed?.should be_true
      subscriber.slot.should_not be_nil
      subscriber.unsubscribe
      subscriber.subscribed?.should be_false
      subscriber.close
    end
  end

  it "rejects a double subscription" do
    with_bus do |name, _|
      subscriber = IPCMail::Bus.open(name)
      subscriber.subscribe
      expect_raises(IPCMail::Error, /already subscribed/) { subscriber.subscribe }
      subscriber.close
    end
  end

  it "rejects more type filters than supported" do
    with_bus do |name, _|
      subscriber = IPCMail::Bus.open(name)
      filters = Array(Int32).new(LibIPC::MAX_TYPES + 1) { |i| i }
      expect_raises(ArgumentError, /type filters/) { subscriber.subscribe(filters) }
      subscriber.close
    end
  end

  it "raises FullError when subscriber slots are exhausted" do
    with_bus(subscribers: 1) do |name, _|
      first = IPCMail::Bus.open(name)
      first.subscribe
      second = IPCMail::Bus.open(name)
      expect_raises(IPCMail::FullError, /subscriber slot/) { second.subscribe }
      first.close
      second.close
    end
  end

  it "refuses the spill policy" do
    name = SpecSupport.shm_name
    expect_raises(ArgumentError, /cannot spill/) do
      IPCMail::Bus.create(name, overflow: :spill)
    end
  end

  it "honors priority order per subscriber" do
    with_bus do |name, publisher|
      subscriber = IPCMail::Bus.open(name)
      subscriber.subscribe
      publisher.publish("low", priority: :normal)
      publisher.publish("high", priority: :high)
      subscriber.receive.text.should eq("high")
      subscriber.receive.text.should eq("low")
      subscriber.close
    end
  end
end