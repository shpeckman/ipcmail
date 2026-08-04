# spec/bus_backpressure_spec.cr
require "./spec_helper"

describe "IPCMail::Bus back-pressure" do
  it "blocks a publisher while a subscriber ring is full and resumes once drained" do
    name      = SpecSupport.shm_name
    publisher = IPCMail::Bus.create(name, capacity: 4, blocks: 64, overflow: :block)
    consumer  = IPCMail::Bus.open(name, overflow: :block)
    begin
      consumer.subscribe

      capacity = publisher.capacity.to_i
      (capacity - 1).times { |i| publisher.publish("fill-#{i}") }

      published = Channel(Bool).new
      spawn do
        publisher.publish("blocked", timeout: 5.seconds)
        published.send(true)
      end

      select
      when published.receive
        fail "publisher should have blocked on the full subscriber ring"
      when timeout(150.milliseconds)
      end

      consumer.receive.text.should eq("fill-0")

      select
      when published.receive
      when timeout(2.seconds)
        fail "publisher did not resume after the ring drained"
      end
    ensure
      consumer.close rescue nil
      publisher.close rescue nil
      IPCMail.unlink("bus://#{name}")
    end
  end

  it "does not hang forever on a subscriber that died with a full ring" do
    name      = SpecSupport.shm_name
    publisher = IPCMail::Bus.create(name, capacity: 4, blocks: 64, overflow: :block)
    begin
      peer = SpecSupport.spawn_peer("subscribe-and-die", name)

      capacity = publisher.capacity.to_i
      capacity.times { |i| publisher.publish("fill-#{i}", timeout: 1.second) rescue nil }

      SpecSupport.kill_peer(peer)

      done = Channel(Int32).new
      spawn do
        done.send(publisher.publish("after-death", timeout: 5.seconds))
      end

      select
      when count = done.receive
        count.should eq(0)
      when timeout(4.seconds)
        fail "publisher hung on a dead subscriber's full ring"
      end
    ensure
      publisher.close rescue nil
      IPCMail.unlink("bus://#{name}")
    end
  end
end
