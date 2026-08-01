# src/ipcmail/errors.cr
module IPCMail
  class Error < Exception
  end

  class SystemError < Error
    getter errno : Errno

    def initialize(context : String, @errno : Errno = Errno.value)
      super("#{context}: #{@errno.message} (#{@errno})")
    end
  end

  class TimeoutError < Error
    def initialize(message = "operation timed out")
      super
    end
  end

  class ClosedError < Error
    def initialize(message = "mailbox is closed")
      super
    end
  end

  class FullError < Error
    def initialize(message = "mailbox is full")
      super
    end
  end

  class MessageTooLarge < Error
  end

  class SchemeError < Error
  end

  class Unsupported < Error
  end

  class CorruptSegment < Error
  end

  class PermissionDenied < Error
  end
end