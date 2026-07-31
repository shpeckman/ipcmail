# examples/timeout.cr
require "../src/ipcmail"

SEGMENT = "shm:///ipcmail_timeout?msgs=8&bsize=128&bcount=8&trace=64"

def sender
  IPCMail.open("shm:///ipcmail_timeout") do |mailbox|
    sleep 100.milliseconds
    mailbox.send("delayed, but inside the deadline", type: 2)
  end
end

def receiver
  IPCMail.create(SEGMENT) do |mailbox|
    puts "[parent] receiving with a 250ms deadline on an empty mailbox"
    started = Time.instant
    if mailbox.receive?(250.milliseconds)
      puts "[parent] unexpected message"
    else
      puts "[parent] timed out cleanly after #{(Time.instant - started).total_milliseconds.round}ms"
    end

    begin
      mailbox.receive(50.milliseconds)
    rescue error : IPCMail::TimeoutError
      puts "[parent] the raising variant reports #{error.class}"
    end

    child = Process.new(PROGRAM_NAME, ["sender"], output: :inherit, error: :inherit)
    puts "[parent] receiving with a 2s deadline while a peer answers after ~100ms"
    started = Time.instant
    message = mailbox.receive(2.seconds)
    puts "[parent] got #{message.inspect} after #{(Time.instant - started).total_milliseconds.round}ms: #{message}"

    idle = 0
    spawn do
      loop do
        idle += 1
        sleep 1.millisecond
      end
    end
    mailbox.receive?(120.milliseconds)
    puts "[parent] other fibers kept running while waiting: #{idle} ticks"

    child.wait
  end
end

if ARGV.first? == "sender"
  sender
else
  puts "== deadlines: timeouts never block the event loop =="
  receiver
end
