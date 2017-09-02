require "../spec_helper"

module Phoenix
  describe Socket do
    describe "#initialize" do
      it "sets defaults" do
        socket = Socket.new()
        socket.host.should eq("localhost")
        socket.path.should eq("/socket")
        socket.port.should eq(4000)
        socket.tls.should eq(false)
        socket.state_change_callbacks.should eq({
          open: [] of ->,
          close: [] of String ->,
          error: [] of String ->,
          message: [] of String ->
        })
        socket.channels.size.should eq(0)
        socket.send_buffer.size.should eq(0)
        socket.ref.should eq(0)
        socket.timeout.should eq(10_000)
        socket.heartbeat_interval_ms.should eq(30_000)
        socket.logger.should eq(nil)
        socket.reconnect_after_ms.call(1_u32).should eq(1000)
      end
    end
  end
end
