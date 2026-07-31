# spec/stream_spec.cr
require "./spec_helper"

describe IPCMail::Socket do
  it "frames typed messages over a unix socket" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path)
    client = uninitialized IPCMail::Socket

    begin
      spawn do
        client = IPCMail::Socket.connect(path)
        client.send("hello", type: 4, priority: :high)
        client.send("world", type: 5)
      end

      connection = server.accept(5.seconds)
      first = connection.receive(5.seconds)
      first.text.should eq("hello")
      first.type.should eq(4_u32)
      first.priority.should eq(IPCMail::Priority::High)
      connection.receive(5.seconds).text.should eq("world")
      connection.close
    ensure
      client.close rescue nil
      server.close
    end
  end

  it "answers the client on the same connection" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path)
    answer = nil

    begin
      spawn do
        client = IPCMail::Socket.connect(path)
        client.send("question")
        answer = client.receive(5.seconds).text
        client.close
      end

      connection = server.accept(5.seconds)
      connection.receive(5.seconds).text.should eq("question")
      connection.send("answer")
      while answer.nil?
        sleep 1.millisecond
      end
      answer.should eq("answer")
      connection.close
    ensure
      server.close
    end
  end

  it "reports the credentials of the peer" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path, authenticate: true)

    begin
      spawn { IPCMail::Socket.connect(path).send("who am i") }
      connection = server.accept(5.seconds)
      credentials = connection.peer_credentials
      credentials.pid.should eq(Process.pid)
      credentials.uid.should eq(LibC.getuid)
      connection.close
    ensure
      server.close
    end
  end

  it "passes bytes through untouched in stream mode" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path, framed: false)

    begin
      spawn do
        client = IPCMail::Socket.connect(path, framed: false)
        client.send("raw bytes")
      end

      connection = server.accept(5.seconds)
      connection.receive(5.seconds).text.should eq("raw bytes")
      connection.close
    ensure
      server.close
    end
  end

  it "times out while accepting and while receiving" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path)

    begin
      server.accept?(60.milliseconds).should be_nil
      spawn { IPCMail::Socket.connect(path) }
      connection = server.accept(5.seconds)
      connection.receive?(60.milliseconds).should be_nil
      connection.close
    ensure
      server.close
    end
  end

  it "raises when the peer goes away" do
    path = SpecSupport.temp_path("sock")
    server = IPCMail::Socket::Server.listen(path)

    begin
      spawn { IPCMail::Socket.connect(path).close }
      connection = server.accept(5.seconds)
      expect_raises(IPCMail::ClosedError) { connection.receive(5.seconds) }
      connection.close
    ensure
      server.close
    end
  end
end

describe IPCMail::Pipe do
  it "carries framed messages in both directions" do
    left, right = IPCMail::Pipe.pair

    begin
      left.send("to the right", type: 1)
      right.receive(2.seconds).text.should eq("to the right")
      right.send("to the left", type: 2, priority: :high)
      message = left.receive(2.seconds)
      message.text.should eq("to the left")
      message.priority.should eq(IPCMail::Priority::High)
    ensure
      left.close
      right.close
    end
  end

  it "connects two endpoints through a named fifo" do
    path = SpecSupport.temp_path("fifo")
    reader = IPCMail::Pipe.fifo(path, :read)
    writer = IPCMail::Pipe.fifo(path, :write)

    begin
      writer.send("through the fifo", type: 12)
      message = reader.receive(2.seconds)
      message.text.should eq("through the fifo")
      message.type.should eq(12_u32)
      reader.receive?(60.milliseconds).should be_nil
    ensure
      writer.close
      reader.close
      reader.unlink
    end
  end

  it "iterates messages until the deadline passes" do
    left, right = IPCMail::Pipe.pair
    seen = [] of String

    begin
      3.times { |index| left.send("m#{index}") }
      right.each(200.milliseconds) { |message| seen << message.text }
      seen.should eq(["m0", "m1", "m2"])
    ensure
      left.close
      right.close
    end
  end
end