# examples/basic.cr
require "../src/ipcmail"

SEGMENT = "shm:///ipcmail_demo?msgs=16&bsize=512&bcount=32&trace=64"
SOCKET  = "unix://./ipcmail_demo.sock"

SOCKET_PATH = IPCMail::Address.parse(SOCKET).target

CONTROL = 1
DATA    = 2

def shm_child
  IPCMail.open("shm:///ipcmail_demo") do |mailbox|
    4.times do
      mailbox.receive(5.seconds) do |view|
        puts "[shm child]     type=#{view.type} priority=#{view.priority}: #{view.text}"
      end
    end
  end
end

def shm_parent
  IPCMail.create(SEGMENT) do |mailbox|
    child = Process.new(PROGRAM_NAME, ["shm-child"], output: :inherit, error: :inherit)

    mailbox.send("standard data message", type: DATA)
    mailbox.send("urgent control message", type: CONTROL, priority: :high)

    head = "gathered ".to_slice
    tail = "into a single block".to_slice
    mailbox.send(head.size + tail.size, type: DATA) do |slice|
      slice.copy_from(head)
      (slice + head.size).copy_from(tail)
    end

    mailbox.send("filled in place, never copied", type: DATA)
    child.wait

    mailbox.as(IPCMail::SharedMemory).trace.each { |record| puts "[trace]         #{record}" }
  end
end

def socket_child
  IPCMail.open(SOCKET) do |client|
    client.send("socket normal", type: DATA)
    client.send("socket high priority", type: CONTROL, priority: :high)
  end
end

def socket_parent
  IPCMail.listen(SOCKET, authenticate: true) do |server|
    child = Process.new(PROGRAM_NAME, ["socket-child"], output: :inherit, error: :inherit)
    connection = server.accept(5.seconds)
    credentials = connection.peer_credentials
    puts "[socket parent] peer pid=#{credentials.pid} uid=#{credentials.uid}"

    2.times do
      message = connection.receive(5.seconds)
      puts "[socket parent] type=#{message.type} priority=#{message.priority}: #{message}"
    end

    connection.close
    child.wait
  end
end

case ARGV.first?
when "shm-child"
  shm_child
when "socket-child"
  socket_child
else
  begin
    puts "== shared memory: priorities, gathered writes, zero copy =="
    shm_parent
    puts
    puts "== unix socket: framed types and peer credentials =="
    socket_parent
  ensure
    File.delete?(SOCKET_PATH)
  end
end