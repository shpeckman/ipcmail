# examples/socket.cr
#
# Unix domain socket transport. A server accepts a connection, checks the peer's
# credentials, and echoes framed messages back.
#
#   crystal run examples/socket.cr
require "../src/ipcmail"

path   = File.join(Dir.tempdir, "ipcmail-example-#{Process.pid}.sock")
server = IPCMail.listen("unix://#{path}")

spawn do
  client = IPCMail.open(IPCMail::Socket, "unix://#{path}")
  client.send("ping")
  puts "client received: #{client.receive(timeout: 5.seconds).text}"
  client.close
end

connection = server.accept(timeout: 5.seconds)
credentials = connection.peer_credentials
puts "peer uid=#{credentials.uid} gid=#{credentials.gid} pid=#{credentials.pid || "unknown"}"

message = connection.receive(timeout: 5.seconds)
connection.send("pong:#{message.text}")

sleep 100.milliseconds
connection.close
server.close
