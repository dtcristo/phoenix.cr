module Phoenix
  VSN = "2.0.0"
  SOCKET_STATES = {
    connecting: 0,
    open: 1,
    closing: 2,
    closed: 3
  }
  DEFAULT_TIMEOUT = 10_000_u32
  DEFAULT_RECONNECT_AFTER_MS = Proc(UInt32, UInt32).new do |tries|
    [1000_u32, 2000_u32, 5000_u32, 10_000_u32].at(tries - 1) { 10_000_u32 }
  end
  # WS_CLOSE_NORMAL = 1000
  CHANNEL_STATES = {
    closed: "closed",
    errored: "errored",
    joined: "joined",
    joining: "joining",
    leaving: "leaving",
  }
  CHANNEL_EVENTS = {
    close: "phx_close",
    error: "phx_error",
    join: "phx_join",
    reply: "phx_reply",
    leave: "phx_leave"
  }
  CHANNEL_LIFECYCLE_EVENTS = [
    CHANNEL_EVENTS[:close],
    CHANNEL_EVENTS[:error],
    CHANNEL_EVENTS[:join],
    CHANNEL_EVENTS[:reply],
    CHANNEL_EVENTS[:leave]
  ]
end
