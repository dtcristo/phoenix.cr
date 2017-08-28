module Phoenix
  class Push
    getter :ref, :timeout
    @ref : String?
    @ref_event : String?
    @received_resp : NamedTuple(status: String, response: String)?

    def initialize(@channel : Channel, @event : String, payload : Hash(Symbol, String)?, @timeout : UInt32)
      @payload = payload || {} of Symbol => String
      # @received_resp : String? = nil
      # @timeout_timer : String? = nil
      @rec_hooks = [] of NamedTuple(status: String, callback: String ->)
      @sent = false
    end

    def resend(timeout)
      @timeout = timeout
      reset()
      send()
    end

    def send
      raise "before has_received?"
      return if has_received?("timeout")
      raise "in send"
    end

    def receive(status, &callback : String ->)
      if has_received?(status)
        @received_resp.try {|resp| yield(resp[:response])}
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

    def match_receive(status, response, ref)
      @rec_hooks.reject { |h| h[:status] == status }.each(&.callback(response))
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
      @ref = @channel.socket.make_ref()
      @ref_event = @channel.reply_event_name(@ref)

      @channel.on @ref_event do |payload|
        cancel_ref_event()
        cancel_timeout()
        @received_resp = payload
        match_receive(payload)
      end

      @timeout_timer = Timer.new(
        trigger("timeout", ""),
        @timeout
      )
      @timeout_timer.schedule_timeout()
    end

    def has_received?(status)
      @received_resp.try do |received_resp|
        return received_resp[:status] == status
      end
      false
    end

    def trigger(status, response)
      @channel.trigger(@ref_event, { status: status, response: response })
    end
  end
end
