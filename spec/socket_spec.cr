# spec/socket_spec.cr
require "./spec_helper"

describe IPCMail::Socket do
  it "round-trips framed messages between client and server" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      accepted = nil.as(IPCMail::Socket?)
      spawn { accepted = server.accept }
      client = IPCMail::Socket.connect(path)
      sleep 20.milliseconds

      client.send("ping", type: 3)
      peer    = accepted.not_nil!
      message = peer.receive
      message.text.should eq("ping")
      message.type.should eq(3_u32)

      peer.send("pong")
      client.receive.text.should eq("pong")

      client.close
      peer.close
    ensure
      server.close
    end
  end

  it "streams raw bytes when unframed" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path, framed: false)
    begin
      accepted = nil.as(IPCMail::Socket?)
      spawn { accepted = server.accept }
      client = IPCMail::Socket.connect(path, framed: false)
      sleep 20.milliseconds

      client.send("rawbytes")
      accepted.not_nil!.receive.text.should eq("rawbytes")

      client.close
      accepted.not_nil!.close
    ensure
      server.close
    end
  end

  it "exposes peer credentials" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      accepted = nil.as(IPCMail::Socket?)
      spawn { accepted = server.accept }
      client = IPCMail::Socket.connect(path)
      sleep 20.milliseconds

      credentials = accepted.not_nil!.peer_credentials
      credentials.pid.should eq(Process.pid)
      credentials.uid.should eq(LibC.getuid)

      client.close
      accepted.not_nil!.close
    ensure
      server.close
    end
  end

  it "times out an idle accept" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      server.accept?(20.milliseconds).should be_nil
      expect_raises(IPCMail::TimeoutError) { server.accept(20.milliseconds) }
    ensure
      server.close
    end
  end

  it "raises ClosedError when the peer closes at a frame boundary" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      accepted = nil.as(IPCMail::Socket?)
      spawn { accepted = server.accept }
      client = IPCMail::Socket.connect(path)
      sleep 20.milliseconds
      peer = accepted.not_nil!

      client.send("last")
      peer.receive.text.should eq("last")
      client.close
      sleep 20.milliseconds

      expect_raises(IPCMail::ClosedError) { peer.receive(500.milliseconds) }
      peer.close
    ensure
      server.close
    end
  end

  it "returns nil when an idle peer sends nothing" do
    path   = SpecSupport.socket_path
    server = IPCMail::Socket::Server.listen(path)
    begin
      accepted = nil.as(IPCMail::Socket?)
      spawn { accepted = server.accept }
      client = IPCMail::Socket.connect(path)
      sleep 20.milliseconds
      peer = accepted.not_nil!

      peer.receive?(100.milliseconds).should be_nil

      client.close
      peer.close
    ensure
      server.close
    end
  end
end
