# examples/monitor.cr
#
# Observability. A monitor attaches read-only to a live segment and reports
# depth, block usage, health, and a trace of recent traffic.
#
#   crystal run examples/monitor.cr
require "../src/ipcmail"

name   = "/ipcmail-example-mon-#{Process.pid}"
server = IPCMail.create("shm://#{name}?msgs=16&bsize=256&trace=32")
client = IPCMail.open("shm://#{name}")

4.times { |i| server.send("event-#{i}", type: i.to_u32) }

monitor = IPCMail.monitor("shm://#{name}")
stats   = monitor.stats

puts "segment      : #{stats.name}"
puts "kind         : #{stats.kind}"
puts "blocks in use: #{stats.blocks_in_use}/#{stats.block_count} (#{stats.usage.round(1)}%)"
puts "attach count : #{stats.attach_count}"
puts "generation   : #{stats.generation}"
puts "damaged      : #{stats.damaged?}"
puts "owner alive  : #{stats.owner_alive?}"
puts "lane depths  : #{stats.lanes}"

puts "recent trace :"
monitor.trace.each { |record| puts "  #{record}" }

monitor.close
client.close
server.close
IPCMail.unlink("shm://#{name}")
