# examples/multiplex.cr
require "../src/ipcmail"

SEGMENT = "shm:///ipcmail_multiplex?msgs=32&bsize=256&bcount=64"
BUS     = "bus:///ipcmail_multiplex_bus?msgs=16&bsize=256&bcount=32"
SOCKET  = "unix://./ipcmail_multiplex.sock"

SOCKET_PATH = IPCMail::Address.parse(SOCKET).target

record Envelope, source : String, message : IPCMail::Message

def pump(source : String, mailbox : IPCMail::Mailbox, channel : Channel(Envelope))
  spawn do
    loop do
      message = mailbox.receive?(5.seconds)
      break unless message
      channel.send(Envelope.new(source, message))
    end
  rescue IPCMail::ClosedError
  end
end

def client
  IPCMail.open("shm:///ipcmail_multiplex") do |shm|
    IPCMail.open(IPCMail::Bus, "bus:///ipcmail_multiplex_bus") do |bus|
      IPCMail.open(SOCKET) do |socket|
        sleep 50.milliseconds
        shm.send("shared memory, normal", type: 10)
        socket.send("unix socket, normal", type: 11)
        shm.send("shared memory, high", type: 20, priority: :high)
        bus.publish("bus broadcast", type: 30, priority: :high)
        socket.send("unix socket, high", type: 21, priority: :high)
        sleep 50.milliseconds
      end
    end
  end
end

def server
  channel = Channel(Envelope).new(16)

  IPCMail.create(SEGMENT) do |shm|
    IPCMail.create(IPCMail::Bus, BUS) do |bus|
      bus.subscribe

      IPCMail.listen(SOCKET) do |server|
        child = Process.new(PROGRAM_NAME, ["client"], output: :inherit, error: :inherit)

        pump("shm", shm, channel)
        pump("bus", bus, channel)

        spawn do
          connection = server.accept(5.seconds)
          pump("socket", connection, channel)
        end

        received = 0
        while received < 5
          select
          when envelope = channel.receive
            received += 1
            puts "[server] #{envelope.source.ljust(6)} type=#{envelope.message.type} " \
                 "priority=#{envelope.message.priority}: #{envelope.message}"
          when timeout(5.seconds)
            puts "[server] idle, giving up"
            break
          end
        end

        child.wait
      end
    end
  end
end

if ARGV.first? == "client"
  client
else
  begin
    puts "== multiplexing: one select loop over shm, bus and socket =="
    server
  ensure
    File.delete?(SOCKET_PATH)
  end
end