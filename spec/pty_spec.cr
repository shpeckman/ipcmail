# spec/pty_spec.cr
require "./spec_helper"

private def with_pty(framed : Bool = false, raw : Bool = true, rows : Int? = nil,
                     columns : Int? = nil, &)
  master, slave = IPCMail::Pty.pair(framed: framed, raw: raw, rows: rows, columns: columns)
  begin
    yield master, slave
  ensure
    slave.close rescue nil
    master.close rescue nil
  end
end

describe IPCMail::Pty do
  it "streams unframed bytes in both directions" do
    with_pty do |master, slave|
      master.send("hello-from-master")
      slave.receive(timeout: 2.seconds).text.should eq("hello-from-master")

      slave.send("hello-from-slave")
      master.receive(timeout: 2.seconds).text.should eq("hello-from-slave")
    end
  end

  it "is byte transparent in raw mode" do
    with_pty do |master, slave|
      payload = Bytes.new(256) { |index| index.to_u8 }
      master.send(payload)

      collected = IO::Memory.new
      while collected.size < payload.size
        message = slave.receive?(timeout: 2.seconds)
        break unless message
        collected.write(message.payload)
      end
      collected.to_slice.should eq(payload)
    end
  end

  it "carries framed messages when framing is enabled" do
    with_pty(framed: true) do |master, slave|
      master.send("framed-payload", type: 7, priority: :high)
      message = slave.receive(timeout: 2.seconds)
      message.text.should eq("framed-payload")
      message.type.should eq(7_u32)
      message.priority.should eq(IPCMail::Priority::High)
    end
  end

  it "defaults to an unframed stream" do
    with_pty do |master, slave|
      master.framed?.should be_false
      slave.framed?.should be_false
    end
  end

  it "reports the endpoint role and slave device" do
    with_pty do |master, slave|
      master.master?.should be_true
      master.slave?.should be_false
      slave.slave?.should be_true
      slave.master?.should be_false

      master.slave_path.should eq(slave.slave_path)
      File.info(master.slave_path).type.character_device?.should be_true
      master.readable?.should be_true
      master.writable?.should be_true
    end
  end

  it "puts the line discipline in raw mode by default" do
    with_pty do |master, slave|
      master.raw?.should be_true
      slave.raw?.should be_true
    end
  end

  it "leaves the line discipline cooked when raw is disabled" do
    with_pty(raw: false) do |master, slave|
      master.raw?.should be_false
      master.raw!
      master.raw?.should be_true
    end
  end

  it "reads and writes the window size" do
    with_pty(rows: 24, columns: 80) do |master, slave|
      size = master.winsize
      size.rows.should eq(24_u16)
      size.columns.should eq(80_u16)
      slave.winsize.rows.should eq(24_u16)

      master.winsize = IPCMail::Pty::Winsize.new(40, 132, 640, 480)
      updated = slave.winsize
      updated.rows.should eq(40_u16)
      updated.columns.should eq(132_u16)
      updated.x_pixels.should eq(640_u16)
      updated.y_pixels.should eq(480_u16)
    end
  end

  it "resizes a single dimension without disturbing the others" do
    with_pty(rows: 24, columns: 80) do |master, slave|
      master.resize(columns: 120)
      size = master.winsize
      size.rows.should eq(24_u16)
      size.columns.should eq(120_u16)
    end
  end

  it "renders the window size" do
    IPCMail::Pty::Winsize.new(24, 80).to_s.should eq("24x80")
  end

  it "collects the output of a process attached to the slave" do
    master = IPCMail::Pty.open
    slave  = File.open(master.slave_path, "r+")
    begin
      process = Process.new("/bin/sh", ["-c", "printf 'child-output\\n'"],
        input: slave, output: slave, error: slave)
      process.wait.success?.should be_true

      collected = IO::Memory.new
      while message = master.receive?(timeout: 500.milliseconds)
        collected.write(message.payload)
        break if collected.to_s.includes?('\n')
      end
      collected.to_s.should eq("child-output\n")
    ensure
      slave.close rescue nil
      master.close rescue nil
    end
  end

  it "reports a hangup once the last slave closes" do
    master, slave = IPCMail::Pty.pair
    begin
      slave.close
      expect_raises(IPCMail::ClosedError) do
        loop { master.receive(timeout: 500.milliseconds) }
      end
    ensure
      master.close rescue nil
    end
  end

  it "refuses to operate once closed" do
    master = IPCMail::Pty.open
    master.close
    master.closed?.should be_true
    expect_raises(IPCMail::ClosedError) { master.winsize }
    expect_raises(IPCMail::ClosedError) { master.raw! }
    expect_raises(IPCMail::ClosedError) { master.send("x") }
  end
end

describe "pty:// endpoints" do
  it "allocates a master through create" do
    master = IPCMail.create(IPCMail::Pty, "pty://")
    begin
      master.master?.should be_true
      master.framed?.should be_false
      master.raw?.should be_true
    ensure
      master.close
    end
  end

  it "reads the geometry and mode from the query string" do
    master = IPCMail.create(IPCMail::Pty, "pty://?rows=30&cols=100&raw=0&framed=1")
    begin
      master.winsize.rows.should eq(30_u16)
      master.winsize.columns.should eq(100_u16)
      master.raw?.should be_false
      master.framed?.should be_true
    ensure
      master.close
    end
  end

  it "attaches to an existing device through open" do
    master = IPCMail.create(IPCMail::Pty, "pty://")
    slave  = IPCMail.open(IPCMail::Pty, "pty://#{master.slave_path}")
    begin
      slave.slave?.should be_true
      master.send("via-uri")
      slave.receive(timeout: 2.seconds).text.should eq("via-uri")
    ensure
      slave.close
      master.close
    end
  end

  it "yields and closes the endpoint for the block form" do
    captured = nil.as(IPCMail::Pty?)
    IPCMail.create(IPCMail::Pty, "pty://") do |master|
      captured = master
      master.closed?.should be_false
    end
    captured.not_nil!.closed?.should be_true
  end

  it "rejects creating a named device" do
    expect_raises(IPCMail::SchemeError, /already exists/) do
      IPCMail.create("pty:///dev/pts/0")
    end
  end

  it "rejects opening without a device path" do
    expect_raises(IPCMail::SchemeError, /device path/) do
      IPCMail.open("pty://")
    end
  end

  it "cannot be unlinked" do
    expect_raises(IPCMail::SchemeError, /cannot unlink/) do
      IPCMail.unlink("pty:///dev/pts/0")
    end
  end

  it "cannot be monitored" do
    expect_raises(ArgumentError, /cannot be inspected/) do
      IPCMail.monitor("pty:///dev/pts/0")
    end
  end
end