# spec/support/peer.cr
require "../../src/ipcmail"

command = ARGV[0]?
name    = ARGV[1]?

abort("usage: peer COMMAND NAME [ARGS]") unless command && name

case command
when "lock-and-die"
  segment = IPCMail::Segment.attach(name, :point_to_point, 5.seconds)
  segment.lock
  STDOUT.puts "ready"
  STDOUT.flush
  sleep 60.seconds
when "claim-and-die"
  count   = (ARGV[2]? || "1").to_i
  segment = IPCMail::Segment.attach(name, :point_to_point, 5.seconds)
  count.times { segment.synchronize { segment.claim_block } }
  STDOUT.puts "ready"
  STDOUT.flush
  sleep 60.seconds
when "subscribe-and-die"
  bus = IPCMail::Bus.open(name, timeout: 5.seconds)
  bus.subscribe
  STDOUT.puts "ready"
  STDOUT.flush
  sleep 60.seconds
when "endpoint-and-die"
  mailbox = IPCMail::SharedMemory.open(name, timeout: 5.seconds)
  STDOUT.puts "ready"
  STDOUT.flush
  sleep 60.seconds
else
  abort("unknown command #{command}")
end
