require "json"

module Phoenix
  struct Message
    # getter :topic, :event, :payload, :ref, :join_ref

    def initialize(params : NamedTuple(topic: String, event: String, payload: JSON::Any, ref: String, join_ref: String?))
      initialize(params[:topic], params[:event], params[:payload], params[:ref], params[:join_ref])
    end

    def initialize(@topic : String, @event : String, @payload : JSON::Any, @ref : String, @join_ref : String?)
    end

    JSON.mapping(
      topic: String,
      event: String,
      payload: JSON::Any,
      ref: String,
      join_ref: String?
    )
  end
end
