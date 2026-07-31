# bin/ipcmail.cr
require "option_parser"
require "../src/ipcmail"

interval = 500.milliseconds
once = false
limit = 16
uri = nil

OptionParser.parse do |parser|
  parser.banner = "usage: ipcmail [options] <uri>"
  parser.on("-i MS", "--interval=MS", "refresh interval in milliseconds") do |value|
    interval = value.to_i.milliseconds
  end
  parser.on("-n N", "--trace=N", "trace records shown per refresh") { |value| limit = value.to_i }
  parser.on("-1", "--once", "print a single snapshot and exit") { once = true }
  parser.on("-h", "--help", "show this help") do
    puts parser
    exit 0
  end
  parser.unknown_args { |args| uri = args.first? }
end

target = uri
unless target
  STDERR.puts "usage: ipcmail [options] <uri>"
  STDERR.puts "example: ipcmail shm:///ipcmail_demo"
  exit 1
end

monitor = begin
  IPCMail.monitor(target, timeout: 2.seconds)
rescue error : IPCMail::Error | ArgumentError
  STDERR.puts "cannot inspect #{target}: #{error.message}"
  exit 1
end

running = true
Signal::INT.trap { running = false }

def render(stats : IPCMail::Monitor::Stats, records : Array(IPCMail::TraceRecord), limit : Int32)
  String.build do |io|
    io << "=== ipcmail segment ===\n"
    io << "name         " << stats.name << '\n'
    io << "kind         " << (stats.kind.bus? ? "bus (publish/subscribe)" : "shm (point to point)") << '\n'
    io << "capacity     " << stats.capacity << " messages per ring\n"
    io << "block size   " << stats.block_size << " bytes\n"
    io << "blocks       " << stats.blocks_in_use << " / " << stats.block_count
    io << " (" << stats.usage.round(1) << "%)\n\n"

    if stats.kind.bus?
      io << "--- subscribers (" << stats.subscribers << " / " << stats.max_subscribers << ") ---\n"
      if stats.rings.empty?
        io << "none\n"
      else
        stats.rings.each do |slot, normal, high|
          io << "slot " << slot << "      normal=" << normal << " high=" << high << '\n'
        end
      end
    else
      io << "--- creator to peer ---\n"
      io << "normal       " << stats.lanes[0] << " / " << stats.capacity << '\n'
      io << "high         " << stats.lanes[1] << " / " << stats.capacity << "\n\n"
      io << "--- peer to creator ---\n"
      io << "normal       " << stats.lanes[2] << " / " << stats.capacity << '\n'
      io << "high         " << stats.lanes[3] << " / " << stats.capacity << '\n'
    end

    io << "\n--- trace ---\n"
    if stats.trace_capacity == 0
      io << "disabled, open the segment with ?trace=N\n"
    elsif records.empty?
      io << "idle\n"
    else
      records.last(limit).each { |record| io << record << '\n' }
    end
  end
end

begin
  loop do
    stats = monitor.stats
    records = monitor.trace(limit)
    print "\033[2J\033[H" unless once
    puts render(stats, records, limit)
    STDOUT.flush
    break if once || !running
    sleep interval
  end
rescue error : IPCMail::Error
  STDERR.puts "segment went away: #{error.message}"
ensure
  monitor.close
end