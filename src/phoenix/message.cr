require "json"

module Phoenix
  struct Message
    def initialize(@topic : String, @event : String, @payload : JSON::Any, @ref : String, @join_ref : String?)
    end

    JSON.mapping(
      topic: { type: String, getter: true, setter: false },
      event: { type: String, getter: true, setter: false },
      payload: { type: JSON::Any, getter: true, setter: false },
      ref: { type: String?, getter: true, setter: false },
      join_ref: { type: String?, getter: true, setter: false }
    )
  end
end
