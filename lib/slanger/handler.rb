# Handler class.
# Handles a client connected via a websocket connection.

require 'active_support/json'
require 'active_support/core_ext/hash'
require 'securerandom'
require 'signature'
require 'fiber'

module Slanger
  class Handler
    def initialize(socket)
      @socket        = socket
      @subscriptions = {}
      authenticate
    end

    # Dispatches message handling to method with same name as the event name
    def onmessage(msg)
      msg   = JSON.parse msg
      event = msg['event'].gsub('pusher:', 'pusher_')

      if event =~ /^pusher_/
        # Pusher event, call method if it exists.
        send(event, msg) if respond_to? event, true
      elsif event =~ /^client-/
        # Client event. Send it to the destination channel.
        msg['socket_id'] = @socket_id

        Channel.from(msg['channel']).try :send_client_message, msg
      end
    rescue JSON::ParserError
      handle_error({ code: '5001', message: "Invalid JSON" })

    rescue StandardError => e
      handle_error({ code: '5000', message: "Internal Server error: #{e.message}, #{e.backtrace}" })
    end

    # Unsubscribe this connection from all the channels on close.
    def onclose
      @subscriptions.each do |channel_id, subscription_id|
        Channel.from(channel_id).try :unsubscribe, subscription_id
      end
    end

    private

    # Verify app key. Send connection_established message to connection if it checks out. Send error message and disconnect if invalid.
    def authenticate
      app_key = @socket.request['path'].split(/\W/)[2]
      if app_key == Slanger::Config.app_key
        @socket_id = SecureRandom.uuid
        send_payload nil, 'pusher:connection_established', { socket_id: @socket_id }
      else
        handle_error({ code: '4001', message: "Could not find app by key #{app_key}" })
        @socket.close_websocket
      end
    end

    # Dispatch to handler method if channel requires authentication, otherwise subscribe.
    def pusher_subscribe(msg)
      channel_id = msg['data']['channel']

      subscription_id = if channel_id =~ /^private-/
                          PrivateSubscription.new(self).handle(msg)
                        elsif channel_id =~ /^presence-/
                          PresenceSubscription.new(self).handle(msg)
                        else
                          subscribe_channel channel_id
                          #Subscription.new(self).handle(msg)
                        end
      @subscriptions[channel_id] = subscription_id
    end

    def pusher_ping(msg)
      send_payload nil, 'pusher:ping'
    end

    def pusher_pong msg; end

    def send_payload *args
      @socket.send payload(*args)
    end

    #TODO: think about moving all subscription stuff into channel classes
    # Add connection to channel subscribers

    def subscribe_channel(channel_id)
      channel = Slanger::Channel.find_or_create_by_channel_id(channel_id)
      send_payload channel_id, 'pusher_internal:subscription_succeeded'
      # Subscribe to the channel and have the events received from it
      # sent to the client's socket.
      subscription_id = channel.subscribe do |msg|
        msg       = JSON.parse(msg)
        # Don't send the event if it was sent by the client
        socket_id = msg.delete 'socket_id'
        @socket.send msg.to_json unless socket_id == @socket_id
      end
    end

    # Message helper method. Converts a hash into the Pusher JSON protocol
    def payload(channel_id, event_name, payload = {})
      { channel: channel_id, event: event_name, data: payload }.to_json
    end

    # HMAC token validation
    def token(channel_id, params=nil)
      string_to_sign = [@socket_id, channel_id, params].compact.join ':'
      HMAC::SHA256.hexdigest(Slanger::Config.secret, string_to_sign)
    end

    def handle_error(error)
      send_payload nil, 'pusher:error', error
    end
  end
end
