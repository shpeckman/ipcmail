# spec/bus_spec.cr
require "./spec_helper"

private def with_bus(**options, &)
  name = SpecSupport.unique("bus")
  publisher = IPCMail::Bus.create(name, **options)
  begin
    yield publisher, name
  ensure
    publisher.close
  end
end

describe IPCMail::Bus do
  it "fans a message out to every subscriber" do
    with_bus do |publisher, name|
      first = IPCMail::Bus.open(name, timeout: 2.seconds)
      second = IPCMail::Bus.open(name, timeout: 2.seconds)
      first.subscribe
      second.subscribe

      begin
        publisher.publish("broadcast", type: 3).should eq(2)
        first.receive(2.seconds).text.should eq("broadcast")
        second.receive(2.seconds).text.should eq("broadcast")
      ensure
        first.close
        second.close
      end
    end
  end

  it "only delivers the types a subscriber asked for" do
    with_bus do |publisher, name|
      alerts = IPCMail::Bus.open(name, timeout: 2.seconds)
      everything = IPCMail::Bus.open(name, timeout: 2.seconds)
      alerts.subscribe(300)
      everything.subscribe

      begin
        publisher.publish("logs", type: 100).should eq(1)
        publisher.publish("intrusion", type: 300, priority: :high).should eq(2)

        alert = alerts.receive(2.seconds)
        alert.text.should eq("intrusion")
        alert.priority.should eq(IPCMail::Priority::High)
        alerts.receive?(80.milliseconds).should be_nil

        everything.receive(2.seconds).text.should eq("intrusion")
        everything.receive(2.seconds).text.should eq("logs")
      ensure
        alerts.close
        everything.close
      end
    end
  end

  it "drops a message nobody subscribed to" do
    with_bus do |publisher, name|
      publisher.publish("into the void", type: 1).should eq(0)
      publisher.segment.blocks_in_use.should eq(0_u32)
    end
  end

  it "releases the block once every subscriber consumed the message" do
    with_bus(blocks: 2) do |publisher, name|
      first = IPCMail::Bus.open(name, timeout: 2.seconds)
      second = IPCMail::Bus.open(name, timeout: 2.seconds)
      first.subscribe
      second.subscribe

      begin
        publisher.publish("shared")
        publisher.segment.blocks_in_use.should eq(1_u32)
        first.receive(2.seconds)
        publisher.segment.blocks_in_use.should eq(1_u32)
        second.receive(2.seconds)
        publisher.segment.blocks_in_use.should eq(0_u32)
      ensure
        first.close
        second.close
      end
    end
  end

  it "publishes without copying the payload" do
    with_bus(block_size: 32) do |publisher, name|
      subscriber = IPCMail::Bus.open(name, timeout: 2.seconds)
      subscriber.subscribe

      begin
        publisher.publish(6, type: 9) { |slice| slice.copy_from("direct".to_slice) }
        subscriber.receive(2.seconds) do |view|
          view.text.should eq("direct")
          view.type.should eq(9_u32)
        end
      ensure
        subscriber.close
      end
    end
  end

  it "frees the slot and the queued blocks when a subscriber leaves" do
    with_bus(blocks: 4) do |publisher, name|
      subscriber = IPCMail::Bus.open(name, timeout: 2.seconds)
      subscriber.subscribe
      publisher.publish("unread")
      publisher.subscribers.should eq(1_u32)
      publisher.segment.blocks_in_use.should eq(1_u32)

      subscriber.unsubscribe
      publisher.subscribers.should eq(0_u32)
      publisher.segment.blocks_in_use.should eq(0_u32)
      subscriber.close
    end
  end

  it "refuses to receive without a subscription" do
    with_bus do |publisher, name|
      expect_raises(IPCMail::Error, /not subscribed/) { publisher.receive(10.milliseconds) }
    end
  end

  it "rejects more type filters than the segment can hold" do
    with_bus do |publisher, name|
      expect_raises(ArgumentError) { publisher.subscribe((1..9).to_a) }
    end
  end

  it "reaches subscribers living in another process" do
    name = SpecSupport.unique("bus_worker")
    publisher = IPCMail::Bus.create(name, block_size: 128, trace: 64)
    publisher.subscribe(200)

    begin
      process = SpecSupport.worker("subscriber", name)
      deadline = Time.instant + 10.seconds
      while publisher.subscribers < 2 && Time.instant < deadline
        sleep 5.milliseconds
      end
      publisher.subscribers.should eq(2_u32)

      publisher.publish("from the parent", type: 100).should eq(1)
      publisher.receive(10.seconds).text.should eq("ack:from the parent")
      process.wait.success?.should be_true
      publisher.trace.size.should be > 0
    ensure
      publisher.close
    end
  end
end