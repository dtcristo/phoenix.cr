module Phoenix
  # Creates a timer that accepts a `delay_calc` proc to perform
  # calculated timeout retries, such as exponential backoff.
  #
  # ```
  # reconnect_timer = Phoenix::Timer.new(
  #   ->{ connect() },
  #   ->(count : UInt32) { [1000_u32, 5000_u32, 10_000_u32].fetch(count - 1) { 10_000_u32 } }
  # )
  # reconnect_timer.schedule_timeout # fires after 1000
  # reconnect_timer.schedule_timeout # fires after 5000
  # reconnect_timer.reset
  # reconnect_timer.schedule_timeout # fires after 1000
  # ```
  class Timer
    @count : UInt32

    # Create a basic timer with a fixed delay
    def initialize(callback : ->, delay : UInt32, repeat : Bool = false)
      initialize(callback, ->(count : UInt32) { delay }, repeat)
    end

    # Create a dynamic timer with a delay based on the count
    def initialize(@callback : ->, @delay_calc : UInt32 -> UInt32, @repeat : Bool = false)
      @count = 0_u32
      @last_id = 0_u32
      @active_timeouts = Hash(UInt32, Bool).new(false)
    end

    # Cancels any previous `schedule_timeout` and resets the count
    def reset
      @count = 0_u32
      @active_timeouts[@last_id] = false
    end

    # Cancels any previous `schedule_timeout` and schedules callback
    def schedule_timeout
      @active_timeouts[@last_id] = false
      id = @last_id += 1
      @active_timeouts[id] = true
      spawn do
        sleep(@delay_calc.call(@count + 1) * 0.001)
        if @active_timeouts[id]
          @count += 1
          @callback.call
          schedule_timeout() if @repeat
        end
      end
      # yield immediately to start the timer ticking
      Fiber.yield
    end
  end
end
