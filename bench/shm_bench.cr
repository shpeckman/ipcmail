# bench/shm_bench.cr
require "./bench_helper"

Bench.section("shm:// point-to-point throughput")

[64, 256, 4096].each do |size|
  name     = Bench.shm_name
  producer = IPCMail::SharedMemory.create(name, capacity: 256, block_size: size, blocks: 512, overflow: :block)
  consumer = IPCMail::SharedMemory.open(name, overflow: :block)
  begin
    Bench.throughput("shm #{size}B", 100_000, Bench.payload(size), producer, consumer)
  ensure
    consumer.close rescue nil
    producer.close rescue nil
    IPCMail.unlink("shm://#{name}")
  end
end

Bench.section("shm:// point-to-point round-trip latency")

[64, 4096].each do |size|
  name  = Bench.shm_name
  local = IPCMail::SharedMemory.create(name, capacity: 64, block_size: size, blocks: 128, overflow: :block)
  echo  = IPCMail::SharedMemory.open(name, overflow: :block)
  begin
    Bench.latency("shm #{size}B", 50_000, Bench.payload(size), local, echo)
  ensure
    echo.close rescue nil
    local.close rescue nil
    IPCMail.unlink("shm://#{name}")
  end
end
