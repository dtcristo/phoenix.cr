module Phoenix
  class Channel
    # :nodoc:
    enum State
      Closed
      Errored
      Joined
      Joining
      Leaving
    end

    protected getter :topic, :socket

    @timeout : UInt32

    EVENTS = {
      close: "phx_close",
      error: "phx_error",
      join: "phx_join",
      reply: "phx_reply",
      leave: "phx_leave"
    }

    LIFECYCLE_EVENTS = [
      EVENTS[:close],
      EVENTS[:error],
      EVENTS[:join],
      EVENTS[:reply],
      EVENTS[:leave]
    ]

    # :nodoc:
    protected def initialize(@topic : String, @params : JSON::Type, @socket : Socket)
      @state = State::Closed
      @bindings = [] of NamedTuple(event: String, ref: UInt32, callback: (JSON::Type, String?, String?) ->)
      @binding_ref = 0_u32
      @timeout = @socket.timeout
      @joined_once = false
      @push_buffer = [] of Push
      @rejoin_timer = Timer.new(
        -> { rejoin_until_connected() },
        @socket.reconnect_after_ms
      )
    end

    protected def setup
      @join_push = join_push = Push.new(self, EVENTS[:join], @params, @timeout)

      join_push.receive "ok" do
        @state = State::Joined
        @rejoin_timer.reset()
        @push_buffer.each(&.send())
        @push_buffer = [] of Push
      end

      join_push.receive "timeout" do
        next unless @state.joining?
        @socket.log("channel", "timeout #{@topic} (#{join_ref()})", join_push.timeout.to_s.as(JSON::Type))
        leave_push = Push.new(
          self,
          EVENTS[:leave],
          {} of String => JSON::Type,
          @timeout
        )
        leave_push.send()
        @state = State::Errored
        join_push.reset()
        @rejoin_timer.schedule_timeout()
      end

      on_close do
        @rejoin_timer.reset()
        @socket.log("channel", "close #{@topic} (#{join_ref()})")
        @state = State::Closed
        @socket.remove(self)
      end

      on_error do |reason|
        next if @state.leaving? || @state.closed?
        @socket.log("channel", "error #{@topic}", reason)
        @state = State::Errored
        @rejoin_timer.schedule_timeout()
      end

      on EVENTS[:reply] do |payload, ref|
        trigger(reply_event_name(ref), payload, ref, nil)
      end
    end

    private def rejoin_until_connected
      @rejoin_timer.schedule_timeout()
      if @socket.connected?
        rejoin()
      end
    end

    # Join the channel
    #
    # Returns a `Push` instance for binding to reply events with `Push#receive`.
    #
    # ```
    # channel.join()
    #   .receive "ok" do |response|
    #     puts "Joined successfully: #{response}"
    #   end
    #   .receive "error" do |response|
    #     puts "Unable to join: #{response}"
    #   end
    # ```
    def join(timeout : UInt32 = @timeout) : Push
      if @joined_once
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
    def on_close(&block : ->) : UInt32
      on(EVENTS[:close], &->(payload : JSON::Type, ref : String?, join_ref : String?) { block.call() })
    end

    # Hook into channel errors
    def on_error(&block : JSON::Type, String?, String? ->) : UInt32
      on(EVENTS[:error], &block)
    end

    # Subscribes to channel events
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
    # Due to unsubscription, "do stuff" won't run,
    # while "do other stuff" will still run on the "event".
    def on(event : String, &block : (JSON::Type, String?, String?) ->) : UInt32
      ref = @binding_ref += 1
      @bindings << { event: event, ref: ref, callback: block }
      ref
    end

    # Unsubscibes to channel events
    def off(event : String, ref : UInt32? = nil)
      @bindings = @bindings.select do |bind|
        !(bind[:event] == event && (ref.nil? || ref == bind[:ref]))
      end
    end

    private def can_push?
      @socket.connected? && @state.joined?
    end

    # Send a message down the channel
    #
    # ```
    # channel.push("new_msg", JSON::Any.new({ "text" => input.as(JSON::Type) }.as(JSON::Type)))
    # ```
    def push(event : String, payload : JSON::Type = {} of String => JSON::Type, timeout : UInt32 = @timeout) : Push
      unless @joined_once
        raise "tried to push '#{event}' to '#{@topic}' before joining. Use channel.join() before pushing events"
      end
      push_event = Push.new(self, event, payload, timeout)
      if can_push?
        push_event.send()
      else
        push_event.start_timeout()
        @push_buffer << push_event
      end
      push_event
    end

    # Leaves the channel
    #
    # Unsubscribes from server events, and instructs channel to terminate on
    # server.
    #
    # ```
    # channel.leave().receive "ok" do
    #   puts "Left successfully"
    # end
    # ```
    def leave(timeout = @timeout) : Push
      @state = State::Leaving
      on_close = Proc(JSON::Type, Nil).new do |payload|
        @socket.log("channel", "leave #{@topic}")
        trigger(EVENTS[:close], payload, nil, nil)
      end
      leave_push = Push.new(
        self,
        EVENTS[:leave],
        {} of String => JSON::Type,
        timeout
      )
      leave_push
        .receive("ok", &on_close)
        .receive("timeout", &on_close)
        .send()
      leave_push.trigger("ok", {} of String => JSON::Type) unless can_push?
      leave_push
    end

    # Default message handler
    @on_message = Proc(String?, JSON::Type, String?, JSON::Type).new do |event, payload, ref|
      payload
    end

    # Overridable message hook
    #
    # Receives all events for specialized message handling before dispatching to
    # the channel callbacks. Must return the payload, modified or unmodified.
    #
    # ```
    # channel.on_message do |event, payload, ref|
    #   # handle payload here
    #   handled_payload
    # end
    # ```
    def on_message(&@on_message : String?, JSON::Type, String? -> JSON::Type)
    end

    protected def member?(topic : String, event : String, payload : JSON::Type, _join_ref : String?) : Bool
      return false unless @topic == topic
      _join_ref.try do |__join_ref|
        if LIFECYCLE_EVENTS.includes?(event) && __join_ref != join_ref()
          # TODO: Log this better, unable to cast to JSON::Type
          # @socket.log("channel", "dropping outdated message", {
          #   "topic" => topic.as(JSON::Type),
          #   "event" => event.as(JSON::Type),
          #   "payload" => payload.as(JSON::Type),
          #   "join_ref" => __join_ref.as(JSON::Type)
          # }.as(JSON::Type))
          @socket.log("channel", "dropping outdated message")
          return false
        end
      end
      true
    end

    protected def join_ref
      @join_push.try(&.ref)
    end

    private def send_join(timeout)
      @state = State::Joining
      @join_push.try(&.resend(timeout))
    end

    private def rejoin(timeout = @timeout)
      return if @state.leaving?
      send_join(timeout)
    end

    protected def trigger(event : String?, payload : JSON::Type, ref : String?, _join_ref : String?)
      handled_payload = @on_message.call(event, payload.as(JSON::Type), ref)
      @bindings
        .select { |bind| bind[:event] == event }
        .map(&.[:callback].call(handled_payload.as(JSON::Type), ref, _join_ref || join_ref()))
    end

    protected def reply_event_name(ref)
      "chan_reply_#{ref}"
    end
  end
end
