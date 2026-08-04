# bench/execution_context_bench.cr
require "wait_group"
require "./bench_helper"

Bench.section("parallel bus consumers scaling (CRYSTAL_WORKERS=#{ENV["CRYSTAL_WORKERS"]? || "unset"})")

payload      = Bench.payload(256)
per_consumer = 50_000

[1, 2, 4, 8].each do |workers|
  name      = Bench.shm_name
  publisher = IPCMail::Bus.create(name, capacity: 256, block_size: 256, blocks: 512, subscribers: 16, overflow: :block)

  consumers  = Fiber::ExecutionContext::Parallel.new("consumers-#{workers}", workers)
  subscribed = WaitGroup.new(workers)
  drained    = WaitGroup.new(workers)

  workers.times do
    consumers.spawn do
      sub = IPCMail::Bus.open(name, overflow: :block)
      sub.subscribe
      subscribed.done
      per_consumer.times { sub.receive(timeout: 30.seconds) { } }
      sub.close
      drained.done
    end
  end

  subscribed.wait

  begin
    started = Time.instant
    per_consumer.times { publisher.publish(payload, timeout: 30.seconds) }
    drained.wait
    elapsed = Time.instant - started

    delivered = per_consumer.to_i64 * workers
    printf "%-28s %12s deliveries %10.0f deliv/s   %8.2f ms\n",
      "#{workers} parallel consumers", delivered, delivered / elapsed.total_seconds, elapsed.total_milliseconds
  ensure
    publisher.close rescue nil
    IPCMail.unlink("bus://#{name}")
  end
end