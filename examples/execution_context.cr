# examples/execution_context.cr
#
# Per-fiber buses across execution contexts. A publisher on the default context
# fans messages out to a pool of subscribers running in parallel, each owning
# its own Bus handle and subscriber slot. This is the supported way to scale a
# bus across cores: one Bus per fiber, never a shared handle.
#
#   crystal run examples/execution_context.cr
require "wait_group"
require "../src/ipcmail"

name     = "/ipcmail-example-ec-#{Process.pid}"
workers  = 4
per_work = 5
total    = workers * per_work

publisher = IPCMail.create(IPCMail::Bus, "bus://#{name}?subs=8&capacity=64&blocks=256")

consumers  = Fiber::ExecutionContext::Parallel.new("consumers", workers)
subscribed = WaitGroup.new(workers)
seen       = Atomic(Int32).new(0)
report     = Channel(String).new

workers.times do |w|
  consumers.spawn do
    sub = IPCMail.open(IPCMail::Bus, "bus://#{name}")
    sub.subscribe
    subscribed.done
    per_work.times do
      sub.receive(timeout: 5.seconds) do |view|
        seen.add(1)
        report.send("worker #{w} saw #{view.text}")
      end
    end
    sub.close
  end
end

subscribed.wait

per_work.times { |i| publisher.publish("event-#{i}") }

total.times { puts report.receive }

puts "delivered #{seen.get}/#{total}"

publisher.close
IPCMail.unlink("bus://#{name}")
