module Phoenix
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
