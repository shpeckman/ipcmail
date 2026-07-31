# spec/execution_context_spec.cr
require "./spec_helper"
require "wait_group"

private class Crew
  getter errors : Channel(Exception)

  def initialize
    @errors = Channel(Exception).new(16)
    @contexts = [] of Fiber::ExecutionContext::Isolated
  end

  def start(name : String, &block : ->) : Nil
    @contexts << Fiber::ExecutionContext::Isolated.new(name) do
      block.call
    rescue error
      @errors.send(error)
    end
  end

  def join : Nil
    @contexts.each &.wait
    @contexts.clear
  end
end

private def collect(channel : Channel(T), count : Int32, crew : Crew,
                    timeout : Time::Span = 15.seconds) : Array(T) forall T
  gathered = [] of T
  count.times do
    select
    when value = channel.receive
      gathered << value
    when error = crew.errors.receive
      fail "worker raised #{error.class}: #{error.message} (after #{gathered.size} of #{count})"
    when timeout(timeout)
      fail "only #{gathered.size} of #{count} results arrived within #{timeout}"
    end
  end
  gathered
end

describe "execution contexts" do
  it "suspends the waiting fiber instead of its thread" do
    name = SpecSupport.unique("ctx_wait")
    mailbox = IPCMail::SharedMemory.create(name)
    context = Fiber::ExecutionContext::Concurrent.new("serial-wait")
    ticks = Atomic(Int32).new(0)
    waiter = Channel(Tuple(UInt64, Time::Span, Bool)).new(1)
    sibling = Channel(UInt64).new(1)

    begin
      context.spawn do
        started = Time.instant
        message = mailbox.receive?(300.milliseconds)
        waiter.send({SpecSupport.thread_id, Time.instant - started, message.nil?})
      end

      context.spawn do
        sibling.send(SpecSupport.thread_id)
        20.times do
          ticks.add(1)
          sleep 10.milliseconds
        end
      end

      thread, elapsed, empty = waiter.receive
      empty.should be_true
      elapsed.should be >= 300.milliseconds

      ticks.get.should be > 10
      thread.should eq(sibling.receive)
      thread.should_not eq(SpecSupport.thread_id)
    ensure
      mailbox.close
    end
  end

  it "suspends a blocked sender instead of its thread" do
    name = SpecSupport.unique("ctx_send")
    creator = IPCMail::SharedMemory.create(name, capacity: 3, blocks: 8)
    peer = IPCMail::SharedMemory.open(name, timeout: 2.seconds)
    context = Fiber::ExecutionContext::Concurrent.new("serial-send")
    ticks = Atomic(Int32).new(0)
    sender = Channel(Bool).new(1)

    begin
      creator.send("a")
      creator.send("b")

      context.spawn do
        sender.send(creator.send?("c", timeout: 400.milliseconds))
      end

      context.spawn do
        20.times do
          ticks.add(1)
          sleep 10.milliseconds
        end
      end

      sender.receive.should be_false
      ticks.get.should be > 10
    ensure
      peer.close
      creator.close
    end
  end

  it "moves messages between two isolated contexts" do
    name = SpecSupport.unique("ctx_isolated")
    creator = IPCMail::SharedMemory.create(name, capacity: 4, blocks: 4,
      overflow: IPCMail::Overflow::Block)
    peer = IPCMail::SharedMemory.open(name, timeout: 2.seconds,
      overflow: IPCMail::Overflow::Block)
    total = 200
    crew = Crew.new
    threads = Channel(UInt64).new(2)
    received = Channel(String).new(total)

    begin
      crew.start("producer") do
        threads.send(SpecSupport.thread_id)
        total.times { |index| creator.send("m#{index}", timeout: 20.seconds) }
      end

      crew.start("consumer") do
        threads.send(SpecSupport.thread_id)
        total.times { received.send(peer.receive(20.seconds).text) }
      end

      messages = collect(received, total, crew, 30.seconds)
      crew.join

      messages.size.should eq(total)
      messages.first.should eq("m0")
      messages.last.should eq("m#{total - 1}")

      observed = collect(threads, 2, crew)
      observed.uniq.size.should eq(2)
      observed.should_not contain(SpecSupport.thread_id)
      creator.segment.blocks_in_use.should eq(0_u32)
    ensure
      crew.join
      peer.close
      creator.close
    end
  end

  it "keeps the segment lock correct while threads contend for it" do
    name = SpecSupport.unique("ctx_contend")
    creator = IPCMail::SharedMemory.create(name, capacity: 8, blocks: 8,
      overflow: IPCMail::Overflow::Block)
    peer = IPCMail::SharedMemory.open(name, timeout: 2.seconds,
      overflow: IPCMail::Overflow::Block)

    senders = 4
    each = 50
    total = senders * each
    crew = Crew.new
    threads = Channel(UInt64).new(senders + 2)
    received = Channel(String).new(total)

    begin
      senders.times do |sender|
        crew.start("sender-#{sender}") do
          threads.send(SpecSupport.thread_id)
          each.times { |index| creator.send("#{sender}:#{index}", timeout: 30.seconds) }
        end
      end

      2.times do |consumer|
        crew.start("consumer-#{consumer}") do
          threads.send(SpecSupport.thread_id)
          loop do
            message = peer.receive?(3.seconds)
            break unless message
            received.send(message.text)
          end
        end
      end

      messages = collect(received, total, crew, 45.seconds)
      crew.join

      messages.size.should eq(total)
      messages.uniq.size.should eq(total)
      senders.times do |sender|
        messages.count(&.starts_with?("#{sender}:")).should eq(each)
      end

      collect(threads, senders + 2, crew).uniq.size.should eq(senders + 2)
      creator.segment.blocks_in_use.should eq(0_u32)
      creator.segment.depth(0).should eq(0_u32)
    ensure
      crew.join
      peer.close
      creator.close
    end
  end

  it "fans a bus message out to subscribers on separate threads" do
    name = SpecSupport.unique("ctx_bus")
    publisher = IPCMail::Bus.create(name, capacity: 8, blocks: 16)
    workers = 3
    crew = Crew.new
    ready = Channel(Nil).new(workers)
    results = Channel(Tuple(UInt64, String)).new(workers)

    begin
      workers.times do |worker|
        crew.start("subscriber-#{worker}") do
          subscriber = IPCMail::Bus.open(name, timeout: 5.seconds)
          subscriber.subscribe(9)
          ready.send(nil)
          results.send({SpecSupport.thread_id, subscriber.receive(20.seconds).text})
          subscriber.close
        end
      end

      collect(ready, workers, crew)
      publisher.publish("broadcast across threads", type: 9, priority: :high,
        timeout: 5.seconds).should eq(workers)

      answers = collect(results, workers, crew)
      crew.join

      answers.map(&.last).uniq.should eq(["broadcast across threads"])
      answers.map(&.first).uniq.size.should eq(workers)
      publisher.segment.blocks_in_use.should eq(0_u32)
    ensure
      crew.join
      publisher.close
    end
  end

  it "serializes framed writes issued from parallel fibers" do
    path = SpecSupport.temp_path("ctx_sock")
    server = IPCMail::Socket::Server.listen(path)
    writers = 6
    size = 128 * 1024
    pool = Fiber::ExecutionContext::Parallel.new("writers", 4)
    crew = Crew.new
    group = WaitGroup.new(writers)
    client = IPCMail::Socket.connect(path)
    connection = server.accept(5.seconds)
    collected = Channel(Tuple(UInt32, Int32, Bool)).new(writers)

    begin
      crew.start("reader") do
        writers.times do
          message = connection.receive(30.seconds)
          expected = ('a' + (message.type.to_i - 1)).ord.to_u8
          collected.send({message.type, message.size, message.payload.all?(&.==(expected))})
        end
      end

      writers.times do |writer|
        pool.spawn do
          payload = Bytes.new(size, ('a' + writer).ord.to_u8)
          client.send(payload, type: writer + 1, timeout: 30.seconds)
        ensure
          group.done
        end
      end
      group.wait

      frames = collect(collected, writers, crew, 45.seconds)
      crew.join

      frames.map(&.[0]).sort.should eq((1..writers).map(&.to_u32))
      frames.each do |type, length, intact|
        length.should eq(size)
        intact.should be_true
      end
      connection.receive?(80.milliseconds).should be_nil
    ensure
      crew.join
      connection.close
      client.close
      server.close
    end
  end

  it "leaves the default context responsive while an isolated fiber blocks" do
    name = SpecSupport.unique("ctx_block")
    mailbox = IPCMail::SharedMemory.create(name)
    ticks = Atomic(Int32).new(0)
    stop = Atomic(Int32).new(0)

    begin
      spawn do
        while stop.get == 0
          ticks.add(1)
          sleep 5.milliseconds
        end
      end

      blocked = Fiber::ExecutionContext::Isolated.new("blocked") do
        mailbox.receive?(300.milliseconds)
      end
      blocked.wait
      stop.set(1)

      ticks.get.should be > 10
    ensure
      stop.set(1)
      mailbox.close
    end
  end
end
