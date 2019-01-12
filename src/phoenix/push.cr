module Phoenix
  # A `Push` is returned from `Channel#join`, `Channel#leave` and `Channel#push`
  # calls. Callbacks can be bound to server replies using `#receive`.
  class Push
    protected getter :ref, :timeout

    @ref : String?
    @ref_event : String?
    @received_resp : JSON::Any?

    # :nodoc:
    protected def initialize(@channel : Channel, @event : String, payload : JSON::Type, @timeout : UInt32)
      @payload = payload
      @receive_hooks = [] of NamedTuple(status: String, callback: JSON::Type ->)
      @sent = false
    end

    protected def resend(@timeout)
      reset()
      send()
    end

    protected def send
      return if has_received?("timeout")
      start_timeout()
      @sent = true
      @channel.socket.push(Message.new(
        @channel.topic,
        @event,
        @payload,
        @ref,
        @channel.join_ref
      ))
    end

    # Register a callback for a push reply of a given status
    #
    # This example shows registering both "ok" and "error" callbacks for a
    # channel join push. This also works for general channel pushes (if
    # configured on the server to reply).
    # ```
    # channel.join
    #   .receive "ok" do |response|
    #     puts "Joined successfully: #{response}"
    #   end
    #   .receive "error" do |response|
    #     puts "Unable to join: #{response}"
    #   end
    # ```
    def receive(status : String, &block : JSON::Type ->) : Push
      if has_received?(status)
        @received_resp.try { |resp| yield(resp["response"].raw.as(JSON::Type)) }
      end
      @receive_hooks << {status: status, callback: block}
      self
    end

    protected def reset
      cancel_ref_event()
      @ref = nil
      @ref_event = nil
      @received_resp = nil
      @sent = false
    end

    private def match_receive(payload : JSON::Any)
      @receive_hooks
        .select { |h| h[:status] == payload["status"]?.to_s }
        .each(&.[:callback].call(payload["response"].raw.as(JSON::Type)))
    end

    private def cancel_ref_event
      @ref_event.try do |ref_event|
        @channel.off(ref_event)
      end
    end

    private def cancel_timeout
      @timeout_timer.try(&.reset())
      @timeout_timer = nil
    end

    protected def start_timeout
      cancel_timeout()
      @ref = ref = @channel.socket.make_ref
      @ref_event = ref_event = @channel.reply_event_name(ref)

      @channel.on ref_event do |payload|
        cancel_ref_event()
        cancel_timeout()
        @received_resp = received_resp = JSON::Any.new(payload)
        match_receive(received_resp)
      end

      @timeout_timer = timeout_timer = Timer.new(
        ->{ trigger("timeout", {} of String => JSON::Type) },
        @timeout
      )
      timeout_timer.schedule_timeout
    end

    private def has_received?(status)
      @received_resp.try do |received_resp|
        return received_resp["status"]? == status
      end
      false
    end

    protected def trigger(status, response)
      @channel.trigger(
        @ref_event,
        {
          "status"   => status.as(JSON::Type),
          "response" => response.as(JSON::Type),
        },
        @ref,
        nil
      )
    end
  end
end
