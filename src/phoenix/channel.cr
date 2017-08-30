module Phoenix
  class Channel
    enum State
      Closed
      Errored
      Joined
      Joining
      Leaving
    end

    getter :topic, :socket

    @timeout : UInt32

    def initialize(@topic : String, @params : JSON::Any, @socket : Socket)
      @state = State::Closed
      @bindings = [] of NamedTuple(event: String, ref: UInt32, callback: JSON::Any ->)
      @binding_ref = 0_u32
      @timeout = @socket.timeout
      @joined_once = false
      @push_buffer = [] of Push
      @rejoin_timer = Timer.new(
        -> { rejoin_until_connected() },
        @socket.reconnect_after_ms
      )
    end

    def setup
      @join_push = Push.new(self, CHANNEL_EVENTS[:join], @params, @timeout)
      @join_push.try do |join_push|
        join_push.receive "ok" do
          raise "joinpush recieve"
          @state = State::Joined
          @rejoin_timer.reset()
          @push_buffer.each(&.send())
          @push_buffer = [] of Push
        end

        join_push.receive "timeout" do
          next unless @state.joining?
          @socket.log("channel", "timeout #{@topic} (#{join_ref()})", join_push.timeout.to_s.as(JSON::Type))
          leave_push = Push.new(self, CHANNEL_EVENTS[:leave], JSON::Any.new(({} of String => JSON::Type).as(JSON::Type)), @timeout)
          leave_push.send()
          @state = State::Errored
          join_push.reset()
          @rejoin_timer.schedule_timeout()
        end
      end

      on_close do
        @rejoin_timer.reset()
        @socket.log("channel", "close #{@topic} (#{join_ref()})")
        @state = State::Closed
        @socket.remove(self)
      end

      on_error do |reason|
        next if @state.leaving? || @state.closed?
        @socket.log("channel", "error #{@topic}", reason.raw)
        @state = State::Errored
        @rejoin_timer.schedule_timeout()
      end

      # on CHANNEL_EVENTS[:reply] do |payload, ref|
      #   trigger(reply_event_name(ref), payload)
      # end
    end

    def rejoin_until_connected
      @rejoin_timer.schedule_timeout()
      if @socket.connected?
        rejoin()
      end
    end

    # Join the channel
    def join(timeout : UInt32 = @timeout) : Push
      if(@joined_once)
        raise "tried to join multiple times. 'join' can only be called a single time per channel instance"
      else
        @joined_once = true
        rejoin(timeout)
        @join_push.try { |join_push| return join_push }
        # TODO: Handle this case better
        raise "error, could not return join_push."
      end
    end

    # Hook into channel close
    def on_close(&block : ->)
      on(CHANNEL_EVENTS[:close], &->(payload : JSON::Any) { block.call() })
    end

    def on_error(&block : String? ->)
      on(CHANNEL_EVENTS[:error], &block)
    end

    # Subscribes on channel events
    #
    # Subscription returns a ref counter, which can be used later to
    # unsubscribe the exact event listener.
    #
    # ```
    # ref_1 = channel.on "event" do
    #   # do stuff
    # end
    # ref_2 = channel.on "event" do
    #   # do other stuff
    # end
    # channel.off("event", ref_1)
    # ```
    # Since unsubscription, "do stuff" won't run,
    # while "do other stuff" will still run on the "event".
    def on(event : String, &block : JSON::Any ->)
      ref = @binding_ref += 1
      @bindings << { event: event, ref: ref, callback: block }
      ref
    end

    def off(event, ref = nil)
      @bindings = @bindings.reject do |bind|
        !(bind[:event] == event && (ref.nil? || ref == bind[:ref]))
      end
    end

    def push(event, payload, timeout = @timeout)
      raise "channel push"
    end

    def leave(timeout = @timeout)
      raise "channel leave"
    end

    def on_message(event, payload, ref)
      payload
    end

    def member?(topic, event, payload, join_ref)
      raise "member?"
    end

    def join_ref
      @join_push.try(&.ref)
    end

    def send_join(timeout)
      @state = State::Joining
      @join_push.try(&.resend(timeout))
    end

    def rejoin(timeout = @timeout)
      return if @state.leaving?
      send_join(timeout)
    end

    # def trigger(event, payload, ref, join_ref)
    def trigger(event, payload, ref)
      handled_payload = on_message(event, payload, ref)
      # @bindings
      #   .reject { |bind| bind[:event] == event }
      #   .map(&.[:callback].call(handled_payload, ref))
    end

    def reply_event_name(ref : String)
      return "chan_reply_#{ref}"
    end
  end
end
