require "../spec_helper"

module Phoenix
  describe Socket do
    describe "#initialize" do
      it "sets defaults" do
        socket = Socket.new

        socket.host.should eq("localhost")
        socket.path.should eq("/socket")
        socket.port.should eq(4000)
        socket.tls.should eq(false)
        socket.state_change_callbacks.should eq({
          open:    [] of ->,
          close:   [] of String ->,
          error:   [] of String ->,
          message: [] of String ->,
        })
        socket.channels.size.should eq(0)
        socket.send_buffer.size.should eq(0)
        socket.ref.should eq(0)
        socket.timeout.should eq(10_000)
        socket.heartbeat_interval_ms.should eq(30_000)
        socket.logger.should eq(nil)
        socket.reconnect_after_ms.call(1_u32).should eq(1000)
      end

      it "overrides some defaults with options" do
        custom_timeout = 5000_u32
        custom_encode = ->(msg : Message) { "sample" }
        custom_decode = ->(raw_msg : String) { Message.new("sample", "sample", JSON::Any.new(nil), nil, nil) }
        custom_heatbeat = 10_000_u32
        custom_reconnect = ->(tries : UInt32) { 10_000_u32 }
        custom_logger = ->(kind : String, log_msg : String, payload : JSON::Any) {}

        socket = Socket.new(
          "https://example.com/sample/socket",
          headers: HTTP::Headers{"Connection" => "keep-alive, Upgrade"},
          timeout: custom_timeout,
          encode: custom_encode,
          decode: custom_decode,
          heartbeat_interval_ms: custom_heatbeat,
          reconnect_after_ms: custom_reconnect,
          logger: custom_logger,
          params: {"userToken" => "123"}
        )

        socket.host.should eq("example.com")
        socket.path.should eq("/sample/socket")
        socket.port.should eq(nil)
        socket.tls.should eq(true)
        socket.headers.includes_word?("Connection", "Upgrade").should be_true
        socket.timeout.should eq(custom_timeout)
        socket.encode.should eq(custom_encode)
        socket.decode.should eq(custom_decode)
        socket.heartbeat_interval_ms.should eq(custom_heatbeat)
        socket.reconnect_after_ms.should eq(custom_reconnect)
        socket.logger.should eq(custom_logger)
        socket.params["userToken"].should eq("123")
      end
    end
  end
end
