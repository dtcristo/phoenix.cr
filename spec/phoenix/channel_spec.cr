require "../spec_helper"

module Phoenix
  describe Channel do
    describe "#initialize" do
      it "sets defaults" do
        socket = Socket.new(timeout: 1234_u32)

        channel = Channel.new(
          "topic",
          JSON::Any.new({"one" => JSON::Any.new("two")}),
          socket
        )

        channel.state.should eq(Channel::State::Closed)
        channel.topic.should eq("topic")
        channel.params["one"].should eq("two")
        channel.socket.should eq(socket)
        channel.timeout.should eq(1234)
        channel.joined_once.should be_false
        channel.push_buffer.should eq([] of Push)
      end
    end
  end
end
