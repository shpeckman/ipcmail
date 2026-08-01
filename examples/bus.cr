# examples/bus.cr
require "../src/ipcmail"

BUS = "bus:///ipcmail_bus"

LOGS    = 100
METRICS = 200
ALERTS  = 300

def worker(id : Int32, types : Array(Int32), expected : Int32)
  IPCMail.open(IPCMail::Bus, BUS) do |bus|
    bus.subscribe(types)

    expected.times do
      message = bus.receive?(3.seconds)
      unless message
        puts "[worker #{id}] timed out"
        break
      end
      puts "[worker #{id}] type=#{message.type} priority=#{message.priority}: #{message}"
    end
  end
end

def publisher
  IPCMail.create(IPCMail::Bus, "#{BUS}?msgs=16&bsize=256&bcount=64&trace=128") do |bus|
    workers = [
      Process.new(PROGRAM_NAME, ["worker", "1", "#{LOGS},#{METRICS},#{ALERTS}", "3"], output: :inherit, error: :inherit),
      Process.new(PROGRAM_NAME, ["worker", "2", "#{ALERTS}", "1"], output: :inherit, error: :inherit),
    ]

    deadline = Time.instant + 5.seconds
    while bus.subscribers < 2 && Time.instant < deadline
      sleep 5.milliseconds
    end

    puts "[publisher] #{bus.subscribers} subscribers are listening"
    puts "[publisher] logs      -> #{bus.publish("disk usage 82%", type: LOGS)} subscriber(s)"
    puts "[publisher] metrics   -> #{bus.publish("cpu 47%", type: METRICS)} subscriber(s)"
    puts "[publisher] alerts    -> #{bus.publish("intrusion detected", type: ALERTS, priority: :high)} subscriber(s)"

    workers.each &.wait
    bus.trace.each { |record| puts "[trace]     #{record}" }
  end
end

if ARGV.first? == "worker"
  worker(ARGV[1].to_i, ARGV[2].split(',').map(&.to_i), ARGV[3].to_i)
else
  puts "== bus: publish and subscribe with type filtering =="
  publisher
end