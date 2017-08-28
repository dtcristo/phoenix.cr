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
        @encode : Message -> String = ->(data : Message) { Serializer.encode(data) },
        @decode : String -> Message = ->(raw_payload : String) { Serializer.decode(raw_payload) },
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
        conn.on_close {}
        conn.close(reason)
        @conn = nil
      end
      callback.try(&.call())
    end

    def connect
      return unless @conn.nil?
      @conn = HTTP::WebSocket.new(@end_point)
      @conn.try do |conn|
        conn.on_close { |event| on_conn_close(event) }
        conn.on_message { |event| on_conn_message(event) }
        conn.on_binary { |data| on_conn_binary(data) }
        spawn do
          begin
            conn.run()
          rescue e
            on_conn_error(e.message || "")
          end
        end
      end
      Fiber.yield
      on_conn_open()
    rescue e
      puts "Exception in connect: #{e.message}"
    end

    def log(kind : String, msg : String, data : JSON::Type = nil.as(JSON::Type))
      @logger.try(&.call(kind, msg, data.as(JSON::Type)))
    end

    # Registers callbacks for connection open events
    def on_open(callback : Proc)
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

    protected def connection_state
      @conn.try do |conn|
        if conn.closed?
          return "closed"
        else
          return "open"
        end
      end
    end

    def connected?
      connection_state() == "open"
    end

    def remove(channel : Channel)
      @channels = @channels.reject { |c| c.join_ref == channel.join_ref }
    end

    # Initiates a new channel for the given topic
    #
    # ```
    # channel = socket.channel("topic:subtopic")
    # ```
    def channel(topic : String, params = {} of Symbol => String)
      puts "channel"
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

    private def on_conn_close(event)
      log("transport", "close", data: event.as(JSON::Type))
      trigger_chan_error()
      @heartbeat_timer.reset()
      @reconnect_timer.schedule_timeout()
      @state_change_callbacks[:close].each(&.call(event))
    end

    private def on_conn_error(error)
      log("transport", "error", data: error.as(JSON::Type))
      trigger_chan_error()
      @state_change_callbacks[:error].each(&.call(error))
    end

    private def on_conn_message(event)
      msg = @decode.call(event)
      if msg.ref == @pending_heartbeat_ref
        @pending_heartbeat_ref = nil
      end
      log("receive", "#{msg.payload["status"]} #{msg.topic} #{msg.event} (#{msg.ref})", data: msg.payload.raw)
    end

    private def on_conn_binary(data)
      raise "trigger_chan_error"
    end

    private def trigger_chan_error
      raise "trigger_chan_error"
    end

    def push(msg : Message)
      encoded = @encode.call(msg)
      log("push", "#{msg.topic} #{msg.event} (#{msg.join_ref}, #{msg.ref})", msg.payload.raw)
      @conn.try(&.send(encoded))
      raise "socket push"
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
      pending_heartbeat_ref = make_ref()
      @pending_heartbeat_ref = pending_heartbeat_ref
      msg = Message.new("phoenix", "heartbeat", JSON::Any.new(nil), pending_heartbeat_ref, nil)
      # push({ topic: "phoenix", event: "heartbeat", payload: {} of String => String, ref: pending_heartbeat_ref, join_ref: nil })
      push(msg)
    end

    private def flush_send_buffer
      puts "flushing send buffer - connected = #{connected?}, (#{@send_buffer.size})"
      if connected? && @send_buffer.size > 0
        @send_buffer.each(&.call())
        @send_buffer = [] of ->
      end
    end
  end
end
