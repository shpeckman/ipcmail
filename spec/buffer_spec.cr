# spec/buffer_spec.cr
require "./spec_helper"

describe IPCMail::Buffer do
  it "creates an object sized exactly as asked" do
    IPCMail::Buffer.create(4096) do |buffer|
      buffer.size.should eq(4096_i64)
      buffer.to_slice.size.should eq(4096)
      buffer.creator?.should be_true
      buffer.name.should start_with("/ipcmail-")
    end
  end

  it "starts out zeroed and keeps the payload at offset zero" do
    IPCMail::Buffer.create(64) do |buffer|
      buffer.to_slice.all?(&.zero?).should be_true
      buffer.to_slice.copy_from("payload".to_slice)

      IPCMail::Buffer.open(buffer.name) do |view|
        String.new(view.to_slice[0, 7]).should eq("payload")
      end
    end
  end

  it "shares writes between two handles on the same object" do
    IPCMail::Buffer.create(16) do |writer|
      IPCMail::Buffer.open(writer.name) do |reader|
        writer.to_slice[0] = 42_u8
        reader.to_slice[0].should eq(42_u8)
        reader.to_slice[1] = 7_u8
        writer.to_slice[1].should eq(7_u8)
      end
    end
  end

  it "maps read only when asked" do
    IPCMail::Buffer.create(16) do |writer|
      writer.to_slice.copy_from("frozen".to_slice)

      IPCMail::Buffer.open(writer.name, read_only: true) do |reader|
        reader.read_only?.should be_true
        String.new(reader.to_slice[0, 6]).should eq("frozen")
        expect_raises(Exception) { reader.to_slice[0] = 1_u8 }
      end
    end
  end

  it "unlinks on close for the creator only" do
    buffer = IPCMail::Buffer.create(16)
    name = buffer.name
    handle = IPCMail::Buffer.open(name)

    handle.close
    IPCMail::Buffer.open(name).close(unlink: false)

    buffer.close
    expect_raises(IPCMail::SystemError, /No such file/) { IPCMail::Buffer.open(name) }
  end

  it "leaves the object behind when the consumer owns it" do
    buffer = IPCMail::Buffer.create(16)
    name = buffer.name
    buffer.to_slice.copy_from("handed over".to_slice)
    buffer.close(unlink: false)

    IPCMail::Buffer.open(name) do |consumer|
      String.new(consumer.to_slice[0, 11]).should eq("handed over")
    end
    IPCMail::Buffer.unlink(name).should be_true
    IPCMail::Buffer.unlink(name).should be_false
  end

  it "refuses to reuse a name that is already taken" do
    IPCMail::Buffer.create(16, name: SpecSupport.unique("buf")) do |buffer|
      expect_raises(IPCMail::SystemError, /File exists/) do
        IPCMail::Buffer.create(16, name: buffer.name)
      end
    end
  end

  it "rejects names a posix object cannot have" do
    expect_raises(ArgumentError) { IPCMail::Buffer.create(16, name: "no-slash") }
    expect_raises(ArgumentError) { IPCMail::Buffer.create(16, name: "/nested/name") }
    expect_raises(ArgumentError) { IPCMail::Buffer.create(0) }
  end

  it "fails immediately on a missing object and waits when given a deadline" do
    missing = SpecSupport.unique("absent")
    expect_raises(IPCMail::SystemError) { IPCMail::Buffer.open(missing) }
    expect_raises(IPCMail::TimeoutError) { IPCMail::Buffer.open(missing, timeout: 80.milliseconds) }

    name = SpecSupport.unique("late")
    spawn do
      sleep 60.milliseconds
      IPCMail::Buffer.create(8, name: name).close(unlink: false)
    end

    buffer = IPCMail::Buffer.open(name, timeout: 3.seconds)
    buffer.size.should eq(8_i64)
    buffer.close(unlink: true)
  end

  it "raises once closed" do
    buffer = IPCMail::Buffer.create(16)
    buffer.close
    buffer.closed?.should be_true
    expect_raises(IPCMail::ClosedError) { buffer.to_slice }
  end

  it "hands a payload to another process out of band" do
    name = SpecSupport.unique("oob")
    mailbox = IPCMail::SharedMemory.create(name, block_size: 256)
    buffer = IPCMail::Buffer.create(1 << 20)

    begin
      slice = buffer.to_slice
      slice.size.times { |index| slice[index] = (index % 251).to_u8 }
      expected = slice.sum(&.to_u64)

      process = SpecSupport.worker("buffer", name, {"IPCMAIL_BUFFER" => buffer.name})
      mailbox.send(buffer.name, type: 1)
      mailbox.receive(10.seconds).text.should eq(expected.to_s)
      process.wait.success?.should be_true
    ensure
      buffer.close
      mailbox.close
    end
  end
end
