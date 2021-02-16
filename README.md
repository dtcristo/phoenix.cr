<div align="center">
  <h1>phoenix.cr</h1>
  <p>
    <strong>
      <a href="http://phoenixframework.org/">Phoenix</a> <a href="https://hexdocs.pm/phoenix/channels.html">Channels</a> client in Crystal
    </strong>
  </p>
  <h3>
    <a href="https://dtcristo.github.io/phoenix.cr/">API Docs</a>
  </h3>
</div>

## Installation

Add this to your application's `shard.yml`:

```yaml
dependencies:
  phoenix:
    github: dtcristo/phoenix.cr
```

## Usage

The example below shows basic usage; connecting to a socket, joining a channel, binding to an event and sending messages.

```crystal
require "phoenix"

# Create socket and connect to it
socket = Phoenix::Socket.new("http://example.com/socket")
socket.connect

# Initiate a channel, bind to an event and join
channel = socket.channel("topic:subtopic")
channel.on "event" do |payload|
  # do stuff with payload
end
channel.join

# Start a loop and send a message down the channel every second
loop do
  sleep 1
  channel.push("new_msg", JSON::Any.new({"text" => JSON::Any.new("Hello world!")}))
end
```

The Phoenix Channels [docs](https://hexdocs.pm/phoenix/channels.html) provide details on implementing sockets and channels on the server side. The phoenix.cr [docs](https://dtcristo.github.io/phoenix.cr/) detail the client side API available for use in your Crystal application.

## Chat example

[examples/chat.cr](https://github.com/dtcristo/phoenix.cr/blob/master/examples/chat.cr) demonstates an example chat client.

Start the [phoenix-chat](https://github.com/dtcristo/phoenix-chat) server example:

```sh
git clone https://github.com/dtcristo/phoenix-chat
cd phoenix-chat
mix deps.get
mix phx.server
```

Run the chat client:

```sh
crystal examples/chat.cr
```

Follow the prompts to enter your name and chat away.

## Todo

- Improve test coverage
- Implement Presence
- Build larger example application

## Contributors

- [dtcristo](https://github.com/dtcristo) David Cristofaro - creator, maintainer

## Credits

- Thanks [chrismccord](https://github.com/chrismccord) and the [Phoenix team](https://github.com/phoenixframework/phoenix/graphs/contributors) for building an amazing web framework. This implementation is based off the original JavaScript [reference implementation](https://github.com/phoenixframework/phoenix/blob/5ec246543e0950e10eab52aba333b644767c885e/assets/js/phoenix.js).
