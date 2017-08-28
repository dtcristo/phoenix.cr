module Phoenix
  module Serializer
    def self.encode(msg : Message) : String
      msg.to_json
    end

    def self.decode(raw_payload : String) : Message
      Message.from_json(raw_payload)
  end
end
