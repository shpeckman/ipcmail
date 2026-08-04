# bench/bus_bench.cr
require "./bench_helper"

Bench.section("bus:// single-subscriber throughput")

[64, 256, 4096].each do |size|
  name      = Bench.shm_name
  publisher = IPCMail::Bus.create(name, capacity: 256, block_size: size, blocks: 512, subscribers: 8, overflow: :block)
  consumer  = IPCMail::Bus.open(name, overflow: :block)
  consumer.subscribe
  begin
    Bench.throughput("bus #{size}B x1", 100_000, Bench.payload(size), publisher, consumer)
  ensure
    consumer.close rescue nil
    publisher.close rescue nil
    IPCMail.unlink("bus://#{name}")
  end
end

Bench.section("bus:// fan-out (messages delivered per publish)")

payload  = Bench.payload(256)
messages = 50_000

[1, 2, 4, 8].each do |subs|
  name      = Bench.shm_name
  publisher = IPCMail::Bus.create(name, capacity: 256, block_size: 256, blocks: 512, subscribers: subs, overflow: :block)

  consumers = Array(IPCMail::Bus).new(subs) do
    bus = IPCMail::Bus.open(name, overflow: :block)
    bus.subscribe
    bus
  end

  drained = Channel(Nil).new
  consumers.each do |bus|
    spawn do
      messages.times { bus.receive(timeout: 30.seconds) { } }
      drained.send(nil)
    end
  end

  begin
    started = Time.instant
    messages.times { publisher.publish(payload, timeout: 30.seconds) }
    subs.times { drained.receive }
    elapsed = Time.instant - started

    delivered = messages.to_i64 * subs
    printf "%-28s %12s deliveries %10.0f deliv/s   %8.2f ms\n",
      "#{subs} subscribers", delivered, delivered / elapsed.total_seconds, elapsed.total_milliseconds
  ensure
    consumers.each &.close rescue nil
    publisher.close rescue nil
    IPCMail.unlink("bus://#{name}")
  end
end