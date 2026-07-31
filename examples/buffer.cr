# examples/buffer.cr
require "../src/ipcmail"

CONTROL = "shm:///ipcmail_frames?msgs=8&bsize=256&bcount=8"

WIDTH  = 640
HEIGHT = 360
DEPTH  =   4
FRAME  = WIDTH * HEIGHT * DEPTH

FRAME_READY  = 1
FRAME_DIGEST = 2

def consumer
  IPCMail.open("shm:///ipcmail_frames") do |mailbox|
    3.times do
      message = mailbox.receive(5.seconds)
      IPCMail::Buffer.open(message.text, read_only: true) do |buffer|
        pixels = buffer.to_slice
        digest = pixels.sum(&.to_u64)
        puts "[consumer] mapped #{buffer.size} bytes at #{buffer.name}, digest #{digest}"
        mailbox.send(digest.to_s, type: FRAME_DIGEST)
      end
    end
  end
end

def producer
  IPCMail.create(CONTROL) do |mailbox|
    child = Process.new(PROGRAM_NAME, ["consumer"], output: :inherit, error: :inherit)

    3.times do |frame|
      buffer = IPCMail::Buffer.create(FRAME)
      pixels = buffer.to_slice
      pixels.size.times { |index| pixels[index] = ((index + frame) % 251).to_u8 }

      started = Time.instant
      mailbox.send(buffer.name, type: FRAME_READY)
      answer = mailbox.receive(5.seconds)
      elapsed = (Time.instant - started).total_microseconds.round

      expected = pixels.sum(&.to_u64)
      status = answer.text == expected.to_s ? "verified" : "MISMATCH"
      puts "[producer] frame #{frame}: #{FRAME} bytes handed over in #{elapsed}us, #{status}"
      buffer.close
    end

    child.wait
  end
end

def handoff
  buffer = IPCMail::Buffer.create(FRAME, name: "/tty-graphics-protocol-demo")
  buffer.to_slice.fill(0xff_u8)
  name = buffer.name
  buffer.close(unlink: false)
  puts "[handoff]  left #{name} in place for a consumer that owns its lifetime"
  puts "[handoff]  reclaimed: #{IPCMail::Buffer.unlink(name)}"
end

if ARGV.first? == "consumer"
  consumer
else
  puts "== out of band: control messages in the mailbox, payload in a raw buffer =="
  producer
  puts
  handoff
end