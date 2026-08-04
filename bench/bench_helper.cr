# bench/bench_helper.cr
require "../src/ipcmail"

module Bench
  @@counter = Atomic(UInt64).new(0)

  def self.token : String
    "ipcmail-bench-#{Process.pid}-#{@@counter.add(1)}"
  end

  def self.shm_name : String
    token
  end

  def self.socket_path : String
    File.join(Dir.tempdir, "#{token}.sock")
  end

  def self.fifo_path : String
    File.join(Dir.tempdir, "#{token}.fifo")
  end

  def self.payload(size : Int32) : Bytes
    bytes = Bytes.new(size)
    bytes.size.times { |i| bytes[i] = (i & 0xff).to_u8 }
    bytes
  end

  struct Throughput
    getter label    : String
    getter messages : Int32
    getter bytes    : Int32
    getter elapsed  : Time::Span

    def initialize(@label, @messages, @bytes, @elapsed)
    end

    def per_second : Float64
      @messages / @elapsed.total_seconds
    end

    def megabytes_per_second : Float64
      (@messages.to_i64 * @bytes) / @elapsed.total_seconds / (1 << 20)
    end
  end

  struct Latency
    getter label   : String
    getter samples : Array(Float64)

    def initialize(@label, @samples)
      @samples.sort!
    end

    def min : Float64
      @samples.first
    end

    def max : Float64
      @samples.last
    end

    def mean : Float64
      @samples.sum / @samples.size
    end

    def percentile(fraction : Float64) : Float64
      return @samples.first if @samples.size == 1
      rank = (fraction * (@samples.size - 1)).round.to_i
      @samples[rank.clamp(0, @samples.size - 1)]
    end
  end

  def self.section(title : String) : Nil
    puts
    puts title
    puts "-" * title.size
    puts
  end

  # Pumps `messages` payloads through `producer` into `consumer`, draining on a
  # separate fiber, and reports sustained one-way throughput.
  def self.throughput(label : String, messages : Int32, payload : Bytes,
                      producer : IPCMail::Mailbox, consumer : IPCMail::Mailbox) : Throughput
    drained = Channel(Nil).new
    spawn do
      messages.times { consumer.receive(timeout: 30.seconds) { } }
      drained.send(nil)
    end

    started = Time.instant
    messages.times { producer.send(payload, timeout: 30.seconds) }
    drained.receive
    elapsed = Time.instant - started

    result = Throughput.new(label, messages, payload.size, elapsed)
    report_throughput(result)
    result
  end

  # Measures round-trip latency: the local endpoint sends, an echo fiber bounces
  # the payload back, and each round trip is timed individually.
  def self.latency(label : String, iterations : Int32, payload : Bytes,
                   local : IPCMail::Mailbox, echo : IPCMail::Mailbox) : Latency
    ready = Channel(Nil).new
    spawn do
      ready.send(nil)
      iterations.times do
        message = echo.receive(timeout: 30.seconds)
        echo.send(message.payload, timeout: 30.seconds)
      end
    end
    ready.receive

    samples = Array(Float64).new(iterations)
    iterations.times do
      started = Time.instant
      local.send(payload, timeout: 30.seconds)
      local.receive(timeout: 30.seconds) { }
      samples << (Time.instant - started).total_microseconds
    end

    result = Latency.new(label, samples)
    report_latency(result)
    result
  end

  def self.report_throughput(result : Throughput) : Nil
    printf "%-28s %12s msg   %10.0f msg/s   %8.1f MiB/s   %8.2f ms\n",
      result.label, result.messages, result.per_second,
      result.megabytes_per_second, result.elapsed.total_milliseconds
  end

  def self.report_latency(result : Latency) : Nil
    printf "%-28s  min %7.2f  mean %7.2f  p50 %7.2f  p90 %7.2f  p99 %7.2f  max %7.2f  (us)\n",
      result.label, result.min, result.mean,
      result.percentile(0.50), result.percentile(0.90),
      result.percentile(0.99), result.max
  end
end
