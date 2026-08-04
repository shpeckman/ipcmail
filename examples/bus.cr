# examples/bus.cr
#
# Broadcast bus. One publisher fans messages out to several subscribers, one of
# which filters by message type.
#
#   crystal run examples/bus.cr
require "../src/ipcmail"

name = "/ipcmail-example-bus-#{Process.pid}"

publisher = IPCMail.create(IPCMail::Bus, "bus://#{name}?subs=8")

done = Channel(String).new

# Subscriber A receives everything.
spawn do
  sub = IPCMail.open(IPCMail::Bus, "bus://#{name}")
  sub.subscribe
  3.times { sub.receive { |view| done.send("A saw type=#{view.type} #{view.text}") } }
  sub.close
end

# Subscriber B only wants type 7.
spawn do
  sub = IPCMail.open(IPCMail::Bus, "bus://#{name}")
  sub.subscribe(7)
  sub.receive { |view| done.send("B saw type=#{view.type} #{view.text}") }
  sub.close
end

sleep 100.milliseconds # let both subscribers register

publisher.publish("alpha", type: 1)
publisher.publish("bravo", type: 7)
publisher.publish("charlie", type: 3)

4.times { puts done.receive }

publisher.close
IPCMail.unlink("bus://#{name}")
