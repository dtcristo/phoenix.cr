module Phoenix
  # :nodoc:
  struct Message
    getter :topic, :event, :payload, :ref, :join_ref

    def initialize(@topic : String, @event : String, @payload : JSON::Any, @ref : String?, @join_ref : String?)
    end
  end
end
