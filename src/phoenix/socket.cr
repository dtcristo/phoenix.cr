require "http/web_socket"
require "uri"

module Phoenix
  class Socket
    getter :end_point, :channels, :timeout, :heartbeat_interval_ms, :reconnect_after_ms, :logger
    protected getter :send_buffer, :ref, :state_change_callbacks

    @ref : UInt32
    @pending_heartbeat_ref : String?

    def initialize(
        @end_point : URI | String,
        @timeout : UInt32 = DEFAULT_TIMEOUT,
        @encode : Message -> String = ->(msg : Message) { Serializer.encode(msg) },
        @decode : String -> Message = ->(raw_msg : String) { Serializer.decode(raw_msg) },
        @heartbeat_interval_ms : UInt32 = 30_000_u32,
        @reconnect_after_ms : UInt32 -> UInt32 = DEFAULT_RECONNECT_AFTER_MS,
        @logger : (String, String, JSON::Type ->)? = nil,
        @params = {} of Symbol => String
      )
      @state_change_callbacks = {
        open: [] of ->,
        close: [] of String ->,
        error: [] of String ->,
        message: [] of String ->
      }
      @channels = [] of Channel
      @send_buffer = [] of ->
      @ref = 0_u32
      @heartbeat_timer = Timer.new(
        -> { send_heartbeat() },
        @heartbeat_interval_ms,
        repeat: true
      )
      @reconnect_timer = Timer.new(
        -> { disconnect(-> { connect() }) },
        @reconnect_after_ms
      )
    end

    def disconnect(callback : (->)? = nil, reason : String? = nil)
      @conn.try do |conn|
        # Clear `on_close` callback to prevent reconnection
        conn.on_close {}
        begin
          conn.close(reason)
        rescue
          # Exception raised if socket already closed. Ignore and continue.
        end
        @conn = nil
      end
      callback.try(&.call())
    end

    def connect
      return unless @conn.nil?
      @conn = HTTP::WebSocket.new(@end_point)
      @conn.try do |conn|
        conn.on_close { |raw_msg| on_conn_close(raw_msg) }
        conn.on_message { |raw_msg| on_conn_message(raw_msg) }
        conn.on_binary { |raw_msg| on_conn_binary(raw_msg) }
        spawn do
          begin
            conn.run()
          rescue e
            reason = e.message || ""
            on_conn_error(reason)
            on_conn_close(reason)
          end
        end
      end
      Fiber.yield
      on_conn_open()
    rescue e
      reason = e.message || ""
      on_conn_error(reason)
      on_conn_close(reason)
    end

    def log(kind : String, msg : String, data : JSON::Type = nil.as(JSON::Type))
      @logger.try(&.call(kind, msg, data.as(JSON::Type)))
    end

    # Registers callbacks for connection open events
    def on_open(callback : ->)
      @state_change_callbacks[:open] << callback
    end

    # Registers callbacks for connection close events
    def on_close(callback : String ->)
      @state_change_callbacks[:close] << callback
    end

    # Registers callbacks for connection error events
    def on_error(callback : String ->)
      @state_change_callbacks[:error] << callback
    end

    # Registers callbacks for connection message events
    def on_message(callback : String ->)
      @state_change_callbacks[:message] << callback
    end

    def connection_state
      @conn.try do |conn|
        return conn.closed? ? "closed" : "open"
      end
      "closed"
    end

    def connected?
      connection_state() == "open"
    end

    def remove(channel : Channel)
      @channels = @channels.select { |c| c.join_ref() != channel.join_ref() }
    end

    # Initiates a new channel for the given topic
    #
    # ```
    # channel = socket.channel("topic:subtopic")
    # ```
    def channel(topic : String, params = JSON::Any.new(({} of String => JSON::Type).as(JSON::Type)))
      chan = Channel.new(topic, params, self)
      chan.setup()
      channels << chan
      chan
    end

    # =====================================
    #            PRIVATE METHODS
    # =====================================

    private def on_conn_open
      log("transport", "connected to #{@end_point}")
      flush_send_buffer()
      @reconnect_timer.reset()
      @heartbeat_timer.schedule_timeout()
      @state_change_callbacks[:open].each(&.call())
    end

    private def on_conn_close(raw_msg)
      log("transport", "close", data: raw_msg.as(JSON::Type))
      trigger_chan_error()
      @heartbeat_timer.reset()
      @reconnect_timer.schedule_timeout()
      @state_change_callbacks[:close].each(&.call(raw_msg))
    end

    private def on_conn_error(raw_msg)
      log("transport", "error", data: raw_msg.as(JSON::Type))
      trigger_chan_error()
      @state_change_callbacks[:error].each(&.call(raw_msg))
    end

    private def on_conn_message(raw_msg)
      msg = @decode.call(raw_msg)
      if msg.ref == @pending_heartbeat_ref
        @pending_heartbeat_ref = nil
      end
      status = msg.payload["status"]?
      ref = msg.ref
      log("receive", "#{status && "#{status} "}#{msg.topic} #{msg.event}#{ref && " (#{ref})"}", data: msg.payload.raw)
      @channels
        .select(&.member?(msg.topic, msg.event, msg.payload, msg.join_ref))
        .each(&.trigger(msg.event, msg.payload, msg.ref, msg.join_ref))
      @state_change_callbacks[:message].each(&.call(raw_msg))
    end

    private def on_conn_binary(data)
      raise "on_conn_binary"
    end

    private def trigger_chan_error
      raise "trigger_chan_error"
    end

    def push(msg : Message)
      callback = Proc(Nil).new do
        encoded = @encode.call(msg)
        @conn.try(&.send(encoded))
      end
      log("push", "#{msg.topic} #{msg.event} (#{msg.join_ref || "nil"}, #{msg.ref})", msg.payload.raw)
      if connected?
        callback.call()
      else
        @send_buffer << callback
      end
    end

    # Return the next message ref
    protected def make_ref : String
      @ref += 1
      return @ref.to_s
    end

    def send_heartbeat
      return unless connected?
      if @pending_heartbeat_ref
        @pending_heartbeat_ref = nil
        log("transport", "heartbeat timeout. Attempting to re-establish connection")
        @conn.try(&.close("hearbeat timeout"))
        return
      end
      @pending_heartbeat_ref = pending_heartbeat_ref = make_ref()
      push(Message.new(
        "phoenix",
        "heartbeat",
        JSON::Any.new(({} of String => JSON::Type).as(JSON::Type)),
        pending_heartbeat_ref,
        nil
      ))
    end

    private def flush_send_buffer
      if connected? && @send_buffer.size > 0
        @send_buffer.each(&.call())
        @send_buffer = [] of ->
      end
    end
  end
end
