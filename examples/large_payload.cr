# examples/large_payload.cr
#
# Out-of-band transfer. A payload far larger than the mailbox block size is
# staged in a shared buffer and handed over by reference with send_large /
# receive_large.
#
#   crystal run examples/large_payload.cr
require "../src/ipcmail"

name   = "/ipcmail-example-oob-#{Process.pid}"
server = IPCMail.create("shm://#{name}?bsize=64&msgs=8")

spawn do
  worker  = IPCMail.open("shm://#{name}")
  message = worker.receive_large(timeout: 5.seconds)
  puts "worker received #{message.size} bytes, checksum=#{message.payload.sum(0_u64)}"
  worker.close
end

payload = Bytes.new(1_000_000) { |i| (i % 256).to_u8 }
puts "sending #{payload.size} bytes over a 64 byte block size"
server.send_large(payload)

sleep 200.milliseconds
server.close
IPCMail.unlink("shm://#{name}")
