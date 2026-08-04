# bench/large_payload_bench.cr
require "./bench_helper"

Bench.section("out-of-band large payload transfer (send_large/receive_large)")

[64 * 1024, 1024 * 1024, 8 * 1024 * 1024].each do |size|
  name     = Bench.shm_name
  producer = IPCMail::SharedMemory.create(name, capacity: 8, block_size: 256, blocks: 16, overflow: :block)
  consumer = IPCMail::SharedMemory.open(name, overflow: :block)
  payload  = Bench.payload(size)
  messages = size >= 4 * 1024 * 1024 ? 200 : 2_000

  drained = Channel(Nil).new
  spawn do
    messages.times { consumer.receive_large(timeout: 30.seconds) }
    drained.send(nil)
  end

  begin
    started = Time.instant
    messages.times { producer.send_large(payload, timeout: 30.seconds) }
    drained.receive
    elapsed = Time.instant - started

    result = Bench::Throughput.new("oob #{size // 1024}KiB", messages, size, elapsed)
    Bench.report_throughput(result)
  ensure
    consumer.close rescue nil
    producer.close rescue nil
    IPCMail.unlink("shm://#{name}")
  end
end