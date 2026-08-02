# src/ipcmail/lib_ipc.cr
lib LibIPC
  SO_PEERCRED     = 17
  MAX_SUBSCRIBERS = 16
  MAX_TYPES       =  8
  SEM_WORDS       =  8

  struct Ucred
    pid : LibC::PidT
    uid : LibC::UidT
    gid : LibC::GidT
  end

  struct Queue
    head : UInt32
    tail : UInt32
  end

  struct Descriptor
    block : UInt32
    size : UInt32
    type : UInt32
  end

  struct Subscriber
    active : UInt32
    pid : UInt32
    types_size : UInt32
    types : UInt32[8]
    rings : Queue[2]
  end

  struct Record
    at : Int64
    seq : UInt64
    type : UInt32
    size : UInt32
    priority : UInt8
    lane : UInt8
    event : UInt8
    reserved : UInt8
  end

  struct Header
    lock : UInt64[8]
    recovery : UInt64[8]
    magic : UInt32
    version : UInt32
    kind : UInt32
    ready : UInt32
    owner : UInt32
    damaged : UInt32
    attach_count : UInt32
    capacity : UInt32
    block_size : UInt32
    block_count : UInt32
    trace_capacity : UInt32
    max_subscribers : UInt32
    subscriber_count : UInt32
    trace_seq : UInt64
    queues : Queue[4]
    subscribers : Subscriber[16]
  end

  fun shm_open(name : LibC::Char*, oflag : LibC::Int, mode : LibC::ModeT) : LibC::Int
  fun shm_unlink(name : LibC::Char*) : LibC::Int
  fun mkfifo(path : LibC::Char*, mode : LibC::ModeT) : LibC::Int
  fun memset(dest : Void*, value : LibC::Int, size : LibC::SizeT) : Void*
  fun sem_init(sem : Void*, pshared : LibC::Int, value : LibC::UInt) : LibC::Int
  fun sem_destroy(sem : Void*) : LibC::Int
  fun sem_post(sem : Void*) : LibC::Int
  fun sem_trywait(sem : Void*) : LibC::Int
end