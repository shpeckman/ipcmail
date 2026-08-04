# examples/shared_memory.cr
#
# Point-to-point shared memory. A worker fiber echoes each message back in
# upper case; the main fiber drives a short request/response exchange.
#
#   crystal run examples/shared_memory.cr
require "../src/ipcmail"

name = "/ipcmail-example-shm-#{Process.pid}"

server = IPCMail.create("shm://#{name}?msgs=16&bsize=256")

spawn do
  worker = IPCMail.open("shm://#{name}")
  3.times do
    message = worker.receive(timeout: 5.seconds)
    worker.send(message.text.upcase)
  end
  worker.close
end

%w[hello shared memory].each do |word|
  server.send(word)
  puts "#{word} -> #{server.receive(timeout: 5.seconds).text}"
end

server.close
IPCMail.unlink("shm://#{name}")
