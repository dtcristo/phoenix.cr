module Phoenix
  # Creates a timer that accepts a `delay_calc` proc to perform
  # calculated timeout retries, such as exponential backoff.
  #
  # ```
  # reconnect_timer = Phoenix::Timer.new(
  #   -> { connect() },
  #   ->(tries : UInt32) { [1000_u32, 5000_u32, 10_000_u32].at(tries - 1) { 10_000_u32 } }
  # )
  # reconnect_timer.schedule_timeout() # fires after 1000
  # reconnect_timer.schedule_timeout() # fires after 5000
  # reconnect_timer.reset()
  # reconnect_timer.schedule_timeout() # fires after 1000
  # ```
  class Timer
    @tries : UInt32

    # Create a basic timer with a fixed delay
    def initialize(callback : ->, delay : UInt32)
      initialize(callback, ->(tries : UInt32) { delay })
    end

    # Create a dynamic timer with a delay based on the number of tries
    def initialize(@callback : ->, @delay_calc : UInt32 -> UInt32)
      @tries = 0_u32
      @current_id = 0_u32
      @active_timeouts = Hash(UInt32, Bool).new(false)
    end

    # Cancels any previous `schedule_timeout` and resets the number of tries
    def reset
      @tries = 0_u32
      @active_timeouts[@current_id] = false
    end

    # Cancels any previous `schedule_timeout` and schedules callback
    def schedule_timeout(repeat = false)
      @active_timeouts[@current_id] = false
      id = @current_id += 1
      @active_timeouts[id] = true
      spawn do
        sleep @delay_calc.call(@tries + 1) * 0.001
        if @active_timeouts[id]
          @tries += 1
          @callback.call()
          schedule_timeout(repeat) if repeat
        end
      end
      # yield immediately to start the timer ticking
      Fiber.yield
    end
  end
end
