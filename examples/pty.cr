# examples/pty.cr
#
# Pseudoterminal. A master endpoint allocates a pty, runs a child process against
# the slave device, and streams its raw output back.
#
#   crystal run examples/pty.cr
require "../src/ipcmail"

master = IPCMail.create(IPCMail::Pty, "pty://?rows=24&cols=80")
puts "slave: #{master.slave_path} (#{master.winsize})"

slave = File.open(master.slave_path, "r+")
child = Process.new("/bin/sh", ["-c", "printf 'one\\ntwo\\nthree\\n'"],
  input: slave, output: slave, error: slave)
child.wait

output = IO::Memory.new
while message = master.receive?(timeout: 200.milliseconds)
  output.write(message.payload)
end
output.to_s.each_line { |line| puts "read: #{line}" }

master.resize(rows: 40, columns: 132)
puts "resized: #{master.winsize}"

slave.close
master.close