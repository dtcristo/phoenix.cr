module Phoenix
  class Push
    getter :ref, :timeout
    @ref : String?
    @ref_event : String?
    @received_resp : JSON::Any?

    def initialize(@channel : Channel, @event : String, payload : JSON::Any, @timeout : UInt32)
      @payload = payload || JSON::Any.new(nil)
      # @received_resp : String? = nil
      # @timeout_timer : String? = nil
      @rec_hooks = [] of NamedTuple(status: String, callback: JSON::Any ->)
      @sent = false
    end

    def resend(@timeout)
      reset()
      send()
    end

    def send
      return if has_received?("timeout")
      start_timeout()
      @sent = true
      @ref.try do |ref|
        @channel.socket.push(Message.new(
          @channel.topic,
          @event,
          @payload,
          ref,
          @channel.join_ref()
        ))
        return
      end
      raise "ref is nil, handle this"
    end

    def receive(status, &callback : JSON::Any ->)
      if has_received?(status)
        @received_resp.try { |resp| yield(resp["response"]) }
        # yield(@received_resp[:response])
      end
      @rec_hooks << { status: status, callback: callback }
      self
    end

    def reset
      cancel_ref_event()
      @ref = nil
      @ref_event = nil
      @received_resp = nil
      @sent = false
    end

    def match_receive(payload)
      @rec_hooks
        .select { |h| h[:status] == payload["status"]? }
        .each(&.[:callback].call(payload["response"]))
    end

    def cancel_ref_event
      return if @ref_event.nil?
      @channel.off(@ref_event)
    end

    def cancel_timeout
      @timeout_timer.try(&.reset())
      @timeout_timer = nil
     end

    def start_timeout()
      cancel_timeout()
      @ref = ref = @channel.socket.make_ref()
      @ref_event = ref_event = @channel.reply_event_name(ref)

      @channel.on ref_event do |payload|
        cancel_ref_event()
        cancel_timeout()
        @received_resp = payload
        match_receive(payload)
      end

      @timeout_timer = timeout_timer = Timer.new(
        -> { trigger("timeout", nil) },
        @timeout
      )
      timeout_timer.schedule_timeout()
    end

    def has_received?(status)
      @received_resp.try do |received_resp|
        return received_resp["status"]? == status
      end
      false
    end

    def trigger(status, response)
      @channel.trigger(@ref_event, JSON::Any.new({ "status" => status.as(JSON::Type), "response" => response.as(JSON::Type) }.as(JSON::Type)), @ref, nil)
    end
  end
end
