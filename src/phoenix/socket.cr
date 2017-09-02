require "http/web_socket"
require "uri"

module Phoenix
  # A single connection is established to the server and channels are
  # multiplexed over the connection. Connect to the server using the Socket
  # class:
  #
  # ```
  # socket = Phoenix::Socket.new(
  #   "http://example.com/socket",
  #   params: {"userToken" => "123"}
  # )
  # socket.connect()
  # ```
  #
  # The Socket constructor takes the endpoint of the socket, the
  # authentication params, as well as options that can be found below, such as
  # configuring the logger, and heartbeat.
  class Socket
    protected getter :host, :path, :port, :tls, :state_change_callbacks,
      :channels, :send_buffer, :ref, :timeout, :heartbeat_interval_ms,
      :reconnect_after_ms, :logger

    @ref : UInt32
    @pending_heartbeat_ref : String?

    # Create a socket with a provided endpoint URI or string
    #
    # ```
    # socket = Phoenix::Socket.new("http://example.com/socket")
    # ```
    #
    # Optionally provide keyword arguments for the following:
    #  * headers: connection headers
    #  * timeout: timeout in milliseconds to trigger push timeouts
    #  * encode: proc to encode outgoing messages
    #  * decode: proc to decode incoming messages
    #  * heartbeat_interval_ms: millisecond interval to send a heartbeat message
    #  * reconnect_after_ms: proc that returns the millisecond reconnect interval
    #  * logger: proc for specialized logging
    #  * params: params to pass when connecting
    def initialize(
        endpoint : URI | String,
        headers : HTTP::Headers = HTTP::Headers.new,
        timeout : UInt32 = DEFAULT_TIMEOUT,
        encode : Message -> String = ->(msg : Message) { Serializer.encode(msg) },
        decode : String -> Message = ->(raw_msg : String) { Serializer.decode(raw_msg) },
        heartbeat_interval_ms : UInt32 = 30_000_u32,
        reconnect_after_ms : UInt32 -> UInt32 = DEFAULT_RECONNECT_AFTER_MS,
        logger : (String, String, JSON::Type ->)? = nil,
        params = {} of String => String
      )
      host, path, port, tls = parse_uri(endpoint)
      initialize(
        host: host,
        path: path,
        port: port,
        tls: tls,
        headers: headers,
        timeout: timeout,
        encode: encode,
        decode: decode,
        heartbeat_interval_ms: heartbeat_interval_ms,
        reconnect_after_ms: reconnect_after_ms,
        logger: logger,
        params: params
      )
    end

    # Create a socket with a provided host, path, port and tls state
    #
    # ```
    # socket = Phoenix::Socket.new(
    #   host: "example.com", path: '/socket', port: 80, tls: false
    # )
    # ```
    #
    # Optional keyword arguments may be provided as above.
    def initialize(
        @host : String = "localhost",
        @path : String = "/socket",
        @port : Int32? = 4000,
        @tls : Bool = false,
        @headers : HTTP::Headers = HTTP::Headers.new,
        @timeout : UInt32 = DEFAULT_TIMEOUT,
        @encode : Message -> String = ->(msg : Message) { Serializer.encode(msg) },
        @decode : String -> Message = ->(raw_msg : String) { Serializer.decode(raw_msg) },
        @heartbeat_interval_ms : UInt32 = 30_000_u32,
        @reconnect_after_ms : UInt32 -> UInt32 = DEFAULT_RECONNECT_AFTER_MS,
        @logger : (String, String, JSON::Type ->)? = nil,
        @params = {} of String => String
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

    private def parse_uri(uri : URI | String)
      uri = URI.parse(uri) if uri.is_a?(String)
      if (host = uri.host) && (path = uri.path)
        tls = uri.scheme == "https" || uri.scheme == "wss"
        return {host, path, uri.port, tls}
      end
      raise ArgumentError.new("No host or path specified which are required.")
    end

    private def endpoint_display()
      protocol = @tls ? "wss" : "ws"
      port = @port.nil? ? "" : ":#{@port}"
      "#{protocol}://#{@host}#{port}#{@path}/websocket?#{conn_query()}"
    end

    private def conn_query
      HTTP::Params.encode(@params.merge({"vsn" => VSN}))
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

    # Initiates the WebSocket and spawns a connection fiber
    def connect
      return unless @conn.nil?
      @conn = HTTP::WebSocket.new(
        @host,
        "#{@path}/websocket?#{conn_query()}",
        port: @port,
        tls: @tls,
        headers: @headers
      )
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

    protected def log(kind : String, msg : String, data : JSON::Type = nil.as(JSON::Type))
      @logger.try(&.call(kind, msg, data.as(JSON::Type)))
    end

    # Registers callbacks for connection open events
    #
    # ```
    # socket.on_open do
    #   puts "open callback"
    # end
    # ```
    def on_open(&block : ->)
      @state_change_callbacks[:open] << block
    end

    # Registers callbacks for connection close events
    #
    # ```
    # socket.on_close do |raw_msg|
    #   puts "close callback: #{raw_msg}"
    # end
    # ```
    def on_close(&block : String ->)
      @state_change_callbacks[:close] << block
    end

    # Registers callbacks for connection error events
    #
    # ```
    # socket.on_error do |raw_msg|
    #   puts "error callback: #{raw_msg}"
    # end
    # ```
    def on_error(&block : String ->)
      @state_change_callbacks[:error] << block
    end

    # Registers callbacks for connection message events
    #
    # ```
    # socket.on_message do |raw_msg|
    #   puts "message callback: #{raw_msg}"
    # end
    # ```
    def on_message(&block : String ->)
      @state_change_callbacks[:message] << block
    end

    private def connection_state
      @conn.try do |conn|
        return conn.closed? ? "closed" : "open"
      end
      "closed"
    end

    # Whether the socket is connected or not
    def connected? : Bool
      connection_state() == "open"
    end

    # Removes a previously initiated channel
    def remove(channel : Channel)
      @channels = @channels.select { |c| c.join_ref() != channel.join_ref() }
    end

    # Initiates a new channel for the given topic
    #
    # ```
    # channel = socket.channel("topic:subtopic")
    # ```
    def channel(topic : String, params = JSON::Any.new(({} of String => JSON::Type).as(JSON::Type))) : Channel
      chan = Channel.new(topic, params, self)
      chan.setup()
      channels << chan
      chan
    end

    private def on_conn_open
      log("transport", "connected to #{endpoint_display()}")
      flush_send_buffer()
      @reconnect_timer.reset()
      @heartbeat_timer.schedule_timeout()
      @state_change_callbacks[:open].each(&.call())
    end

    private def on_conn_close(raw_msg : String)
      log("transport", "close", data: raw_msg.as(JSON::Type))
      trigger_chan_error()
      @heartbeat_timer.reset()
      @reconnect_timer.schedule_timeout()
      @state_change_callbacks[:close].each(&.call(raw_msg))
    end

    private def on_conn_error(raw_msg : String)
      log("transport", "error", data: raw_msg.as(JSON::Type))
      trigger_chan_error()
      @state_change_callbacks[:error].each(&.call(raw_msg))
    end

    private def on_conn_message(raw_msg : String)
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
      @channels.each do |channel|
        channel.trigger(
          CHANNEL_EVENTS[:error],
          JSON::Any.new(({} of String => JSON::Type).as(JSON::Type)),
          nil,
          nil
        )
      end
    end

    protected def push(msg : Message)
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

    private def send_heartbeat
      return unless connected?
      if @pending_heartbeat_ref
        @pending_heartbeat_ref = nil
        log("transport", "heartbeat timeout. Attempting to re-establish connection")
        @conn.try(&.close("hearbeat timeout"))
        return
      end
      @pending_heartbeat_ref = make_ref()
      push(Message.new(
        "phoenix",
        "heartbeat",
        JSON::Any.new(({} of String => JSON::Type).as(JSON::Type)),
        @pending_heartbeat_ref,
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
