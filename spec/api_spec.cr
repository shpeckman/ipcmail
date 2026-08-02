# spec/api_spec.cr
require "./spec_helper"

describe IPCMail::Address do
  it "splits a shared memory uri" do
    address = IPCMail::Address.parse("shm:///demo?msgs=16&bsize=512&bcount=8&overflow=block")
    address.scheme.should eq("shm")
    address.target.should eq("/demo")
    address.integer?("capacity", "msgs").should eq(16)
    address.integer?("block_size", "bsize").should eq(512)
    address.integer?("blocks", "bcount").should eq(8)
    address.overflow?.should eq(IPCMail::Overflow::Block)
  end

  it "keeps relative socket paths intact" do
    IPCMail::Address.parse("unix://./run/ipcmail.sock").target.should eq("./run/ipcmail.sock")
    IPCMail::Address.parse("unix:///tmp/ipcmail.sock").target.should eq("/tmp/ipcmail.sock")
  end

  it "reads booleans and file modes" do
    address = IPCMail::Address.parse("unix:///tmp/x.sock?stream=true&mode=660&authenticate=yes")
    address.framed?.should be_false
    address.mode?.should eq(0o660)
    address.boolean?("authenticate").should be_true
  end

  it "rejects unknown schemes" do
    expect_raises(ArgumentError, /unsupported scheme/) { IPCMail::Address.parse("tcp://localhost") }
  end
end

describe IPCMail do
  it "creates and opens a segment from a uri" do
    name = SpecSupport.unique("uri")
    IPCMail.create("shm://#{name}?msgs=8&bsize=64&bcount=4&trace=8") do |creator|
      IPCMail.open("shm://#{name}") do |peer|
        creator.send("uri driven", type: 2)
        peer.receive(2.seconds).text.should eq("uri driven")
      end
    end
  end

  it "creates a bus from a uri" do
    name = SpecSupport.unique("uri_bus")
    IPCMail.create("bus://#{name}?subs=4") do |publisher|
      publisher.should be_a(IPCMail::Bus)
      IPCMail.open("bus://#{name}") do |subscriber|
        subscriber.as(IPCMail::Bus).subscribe(1)
        publisher.as(IPCMail::Bus).publish("hello", type: 1).should eq(1)
        subscriber.receive(2.seconds).text.should eq("hello")
      end
    end
  end

  it "listens and connects over a uri" do
    path = SpecSupport.temp_path("uri_sock")
    IPCMail.listen("unix://#{path}") do |server|
      clients = Channel(IPCMail::Mailbox).new(1)
      spawn do
        client = IPCMail.open("unix://#{path}")
        client.send("uri socket")
        clients.send(client)
      end
      connection = server.accept(5.seconds)
      connection.receive(5.seconds).text.should eq("uri socket")
      connection.close
      clients.receive.close
    end
  end

  it "opens both ends of a fifo from a uri" do
    path = SpecSupport.temp_path("uri_fifo")
    reader = IPCMail.create("fifo://#{path}?direction=read")
    writer = IPCMail.open("fifo://#{path}?direction=write")

    begin
      writer.send("named pipe")
      reader.receive(2.seconds).text.should eq("named pipe")
    ensure
      writer.close
      reader.close
      File.delete?(path)
    end
  end

  it "refuses to create a listening socket" do
    expect_raises(IPCMail::SchemeError, /IPCMail.listen/) { IPCMail.create("unix:///tmp/nope.sock") }
  end

  it "returns concrete types from typed create and open" do
    name = SpecSupport.unique("typed_bus")
    IPCMail.create(IPCMail::Bus, "bus://#{name}?subs=4") do |publisher|
      IPCMail.open(IPCMail::Bus, "bus://#{name}") do |subscriber|
        subscriber.subscribe(1)
        publisher.publish("typed", type: 1).should eq(1)
        subscriber.receive(2.seconds).text.should eq("typed")
      end
    end
  end

  it "guards the typed form against a mismatched scheme" do
    expect_raises(IPCMail::SchemeError, /expected a bus/) do
      IPCMail.create(IPCMail::Bus, "shm:///wrong")
    end
  end

  it "accepts a direction keyword instead of a query param" do
    path = SpecSupport.temp_path("kw_fifo")
    reader = IPCMail.create(IPCMail::Pipe, "fifo://#{path}", direction: :read)
    writer = IPCMail.open(IPCMail::Pipe, "fifo://#{path}", direction: :write)

    begin
      writer.send("kw pipe")
      reader.receive(2.seconds).text.should eq("kw pipe")
    ensure
      writer.close
      reader.close
      File.delete?(path)
    end
  end

  it "fills a stream payload in place" do
    path = SpecSupport.temp_path("inplace_sock")
    IPCMail.listen(IPCMail::Socket::Server, "unix://#{path}") do |server|
      clients = Channel(IPCMail::Mailbox).new(1)
      spawn do
        client = IPCMail.open(IPCMail::Socket, "unix://#{path}")
        client.send(5, type: 7) { |slice| slice.copy_from("hello".to_slice) }
        clients.send(client)
      end
      connection = server.accept(5.seconds)
      message = connection.receive(5.seconds)
      message.type.should eq(7)
      message.text.should eq("hello")
      connection.close
      clients.receive.close
    end
  end
end

describe IPCMail::Monitor do
  it "reports the state of a live segment" do
    name = SpecSupport.unique("monitor")
    IPCMail.create("shm://#{name}?msgs=8&bsize=64&bcount=4&trace=16") do |creator|
      creator.send("watch me", type: 3, priority: :high)
      monitor = IPCMail.monitor("shm://#{name}")

      begin
        stats = monitor.stats
        stats.kind.should eq(IPCMail::Kind::PointToPoint)
        stats.capacity.should eq(8_u32)
        stats.block_size.should eq(64_u32)
        stats.block_count.should eq(4_u32)
        stats.blocks_in_use.should eq(1_u32)
        stats.lanes[1].should eq(1_u32)
        stats.usage.should be_close(25.0, 0.01)

        records = monitor.trace
        records.size.should eq(1)
        records[0].type.should eq(3_u32)
        records[0].event.should eq(IPCMail::Event::Send)
      ensure
        monitor.close
      end
    end
  end

  it "reports the subscribers of a bus" do
    name = SpecSupport.unique("monitor_bus")
    IPCMail.create("bus://#{name}?subs=4") do |publisher|
      publisher.as(IPCMail::Bus).subscribe
      monitor = IPCMail.monitor("bus://#{name}")

      begin
        stats = monitor.stats
        stats.kind.should eq(IPCMail::Kind::Bus)
        stats.subscribers.should eq(1_u32)
        stats.max_subscribers.should eq(4_u32)
        stats.rings.size.should eq(1)
      ensure
        monitor.close
      end
    end
  end
end
