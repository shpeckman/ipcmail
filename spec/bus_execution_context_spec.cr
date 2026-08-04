# spec/bus_execution_context_spec.cr
require "wait_group"
require "./spec_helper"

describe "IPCMail::Bus across execution contexts" do
  it "fans out to per-fiber subscribers running in a parallel context" do
    name      = SpecSupport.shm_name
    publisher = IPCMail::Bus.create(name, capacity: 64, blocks: 256, subscribers: 8)

    consumers    = Fiber::ExecutionContext::Parallel.new("consumers", 4)
    subscribed   = WaitGroup.new(4)
    seen         = Atomic(Int32).new(0)
    per_consumer = 25

    begin
      4.times do
        consumers.spawn do
          sub = IPCMail::Bus.open(name)
          begin
            sub.subscribe
            subscribed.done
            per_consumer.times do
              sub.receive(timeout: 5.seconds) { seen.add(1) }
            end
          ensure
            sub.close rescue nil
          end
        end
      end

      subscribed.wait

      per_consumer.times { |i| publisher.publish("event-#{i}").should eq(4) }

      deadline = Time.instant + 5.seconds
      until seen.get == 4 * per_consumer || Time.instant > deadline
        sleep 5.milliseconds
      end

      seen.get.should eq(4 * per_consumer)
    ensure
      publisher.close rescue nil
      IPCMail.unlink("bus://#{name}")
    end
  end

  it "keeps the sender cache safe under parallel publishers on one bus each" do
    name     = SpecSupport.shm_name
    creator  = IPCMail::Bus.create(name, capacity: 128, blocks: 512, subscribers: 4, overflow: :block)
    consumer = IPCMail::Bus.open(name, overflow: :block)
    consumer.subscribe

    publishers = Fiber::ExecutionContext::Parallel.new("publishers", 4)
    published  = WaitGroup.new(4)
    per_pub    = 50
    total      = 4 * per_pub

    begin
      4.times do |p|
        publishers.spawn do
          bus = IPCMail::Bus.open(name, overflow: :block)
          begin
            per_pub.times { |i| bus.publish("p#{p}-#{i}", timeout: 10.seconds) }
          ensure
            bus.close rescue nil
            published.done
          end
        end
      end

      collector = Channel(Int32).new
      spawn do
        count = 0
        begin
          total.times do
            consumer.receive(timeout: 5.seconds) { count += 1 }
          end
        rescue IPCMail::TimeoutError
        end
        collector.send(count)
      end

      published.wait
      collector.receive.should eq(total)
    ensure
      consumer.close rescue nil
      creator.close rescue nil
      IPCMail.unlink("bus://#{name}")
    end
  end

  it "isolates a blocking receive loop in an isolated context" do
    name      = SpecSupport.shm_name
    publisher = IPCMail::Bus.create(name, capacity: 16, blocks: 64, subscribers: 2)

    result = Channel(String).new
    worker = Fiber::ExecutionContext::Isolated.new("bus-worker") do
      sub = IPCMail::Bus.open(name)
      sub.subscribe
      result.send(sub.receive(timeout: 5.seconds, &.text) || "none")
      sub.close
    end

    begin
      sleep 100.milliseconds
      publisher.publish("from-default").should eq(1)
      result.receive.should eq("from-default")
    ensure
      worker.wait rescue nil
      publisher.close rescue nil
      IPCMail.unlink("bus://#{name}")
    end
  end
end
