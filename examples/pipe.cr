# examples/pipe.cr
#
# Named FIFO pipe. A writer streams framed messages to a reader through a fifo://
# endpoint.
#
#   crystal run examples/pipe.cr
require "../src/ipcmail"

path = File.join(Dir.tempdir, "ipcmail-example-#{Process.pid}.fifo")

spawn do
  reader = IPCMail.open("fifo://#{path}?direction=read")
  3.times { puts "read: #{reader.receive(timeout: 5.seconds).text}" }
  reader.close
  File.delete?(path)
end

writer = IPCMail.create("fifo://#{path}?direction=write")
%w[one two three].each { |word| writer.send(word) }
writer.close
sleep 200.milliseconds
