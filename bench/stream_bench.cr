# bench/stream_bench.cr
require "./bench_helper"

Bench.section("stream throughput (framed)")

[64, 4096].each do |size|
  left, right = IPCMail::Pipe.pair
  begin
    Bench.throughput("pipe pair #{size}B", 100_000, Bench.payload(size), left, right)
  ensure
    left.close rescue nil
    right.close rescue nil
  end
end

[64, 4096].each do |size|
  path   = Bench.socket_path
  server = IPCMail::Socket::Server.listen(path)
  accepted = Channel(IPCMail::Socket).new
  spawn { accepted.send(server.accept(timeout: 30.seconds)) }
  client = IPCMail::Socket.connect(path)
  connection = accepted.receive
  begin
    Bench.throughput("unix socket #{size}B", 100_000, Bench.payload(size), client, connection)
  ensure
    client.close rescue nil
    connection.close rescue nil
    server.close rescue nil
    File.delete?(path)
  end
end

[64, 4096].each do |size|
  path = Bench.fifo_path
  reader = nil.as(IPCMail::Pipe?)
  opened = Channel(Nil).new
  spawn do
    reader = IPCMail::Pipe.fifo(path, :read, timeout: 30.seconds)
    opened.send(nil)
  end
  writer = IPCMail::Pipe.fifo(path, :write, timeout: 30.seconds)
  opened.receive
  consumer = reader.not_nil!
  begin
    Bench.throughput("fifo #{size}B", 100_000, Bench.payload(size), writer, consumer)
  ensure
    writer.close rescue nil
    consumer.close rescue nil
    File.delete?(path)
  end
end

Bench.section("stream round-trip latency (framed)")

[64, 4096].each do |size|
  left, right = IPCMail::Pipe.pair
  begin
    Bench.latency("pipe pair #{size}B", 50_000, Bench.payload(size), left, right)
  ensure
    left.close rescue nil
    right.close rescue nil
  end
end

[64, 4096].each do |size|
  path   = Bench.socket_path
  server = IPCMail::Socket::Server.listen(path)
  accepted = Channel(IPCMail::Socket).new
  spawn { accepted.send(server.accept(timeout: 30.seconds)) }
  client = IPCMail::Socket.connect(path)
  connection = accepted.receive
  begin
    Bench.latency("unix socket #{size}B", 50_000, Bench.payload(size), client, connection)
  ensure
    client.close rescue nil
    connection.close rescue nil
    server.close rescue nil
    File.delete?(path)
  end
end