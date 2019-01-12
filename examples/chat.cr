require "../src/phoenix"
require "colorize"

# A custom logger proc for debugging socket and channel events
logger = Proc(String, String, JSON::Type, Nil).new do |kind, log_msg, payload|
  log = if payload.nil? || payload == ""
          "#{kind}: #{log_msg}"
        else
          "#{kind}: #{log_msg} - #{payload}"
        end
  puts log.colorize(:dark_gray)
end

# Connect to a socket on localhost, provide custom logger defined above
socket = Phoenix::Socket.new("http://localhost:4000/socket", logger: logger)
socket.connect

# Prompt for the user's name
puts "What's your name?"
name = gets

# Initiate the "chat:lobby" channel providing "name" param
channel = socket.channel("chat:lobby", {"name" => name.as(JSON::Type)})

# Bind to inbound "new_msg" events, parse as JSON and print the payload
channel.on "new_msg" do |payload|
  payload = JSON::Any.new(payload)
  puts "#{payload["name"]?} says: #{payload["text"]?}"
end

# Join the channel and bind to the "ok" and "error" events
channel.join
  .receive "ok" do |response|
    puts "Joined successfully: #{response}".colorize(:green)
  end
  .receive "error" do |response|
    puts "Unable to join: #{response}".colorize(:red)
  end

# Start a loop reading user input, and sending it down the channel
loop do
  input = gets
  channel.push("new_msg", {"text" => input.as(JSON::Type)})
end
