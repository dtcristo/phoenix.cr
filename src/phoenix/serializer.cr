module Phoenix
  # :nodoc:
  module Serializer
    def self.encode(msg : Message) : String
      JSON.build do |json|
        json.array do
          json.raw msg.join_ref.to_json
          json.raw msg.ref.to_json
          json.string msg.topic
          json.string msg.event
          json.raw msg.payload.to_json
        end
      end
    end

    def self.decode(raw_msg : String) : Message
      json = JSON.parse(raw_msg)
      Message.new(
        json[2].as_s,
        json[3].as_s,
        JSON::Any.new(json[4].raw),
        json[1].as_s?,
        json[0].as_s?
      )
    end
  end
end
