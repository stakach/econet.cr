require "spec"
require "http/server"
require "../src/econet"

class SpecCloud
  LOCATION_RESPONSE = <<-JSON
    {
      "success": true,
      "results": {"locations": [{"equiptments": [
        {
          "device_type": "WH", "device_name": "heater", "serial_number": "heater-1",
          "@NAME": {"value": "Water heater"}, "@TYPE": "heatpumpWaterHeaterGen5",
          "@SETPOINT": {"value": 136, "constraints": {"lowerLimit": 110, "upperLimit": 140, "units": "deg F", "formatDecimal": 0}},
          "@MODE": {"value": 2, "status": "Heat Pump ", "constraints": {"enumText": ["Off", "Energy Saver", "Heat Pump ", "Electric/Gas"]}},
          "@ENABLED": {"value": 1}, "@AWAYCONFIG": false, "@AWAY": false,
          "@SCHEDULESTATUS": "Schedule overridden", "@RUNNING": ""
        },
        {
          "device_type": "WH", "device_name": "gas-heater", "serial_number": "heater-2",
          "@TYPE": "gasWaterHeater",
          "@SETPOINT": {"value": 49, "constraints": {"lowerLimit": 45, "upperLimit": 60, "units": "deg C", "formatDecimal": 1}}
        },
        {
          "device_type": "HVAC", "device_name": "hvac", "serial_number": "hvac-1",
          "@MODE": {"value": 0, "status": "Emergency Heat", "constraints": {"enumText": ["Heating", "Vendor mode", "Cooling", "Auto", "Emergency Heat"]}},
          "@COOLSETPOINT": {"value": 76, "constraints": {"lowerLimit": 52, "upperLimit": 92}},
          "@HEATSETPOINT": {"value": 68, "constraints": {"lowerLimit": 48, "upperLimit": 90}},
          "@FANSPEED": {"value": 2, "constraints": {"enumText": ["Auto", "Low", "Med. Hi"]}},
          "@FANMODE": {"value": 0, "constraints": {"enumText": ["Auto", "On/Continuous"]}},
          "@DEHUMSETPOINT": {"value": 50, "constraints": {"lowerLimit": 40, "upperLimit": 60}},
          "zoning_devices": [
            {"serial_number": "zone-1", "@NAME": {"value": "Zone"}, "@ZONE_ID_NAME": "Zone 1"}
          ]
        },
        {"device_type": "WH", "error": "Unavailable"},
        {"device_type": "OTHER", "serial_number": "unknown", "device_name": "unknown"}
      ]}]}
    }
    JSON

  property location_response = LOCATION_RESPONSE
  getter actions = [] of JSON::Any
  getter url : String

  def initialize
    @server = HTTP::Server.new { |context| serve(context) }
    address = @server.bind_tcp("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{address.port}/api/v/1"
    spawn { @server.listen }
  end

  def login(broker : SpecBroker? = nil) : EcoNet::Client
    EcoNet::Client.login("test@example.invalid", "fixture-password", rest_url: url, mqtt_transport: broker.try(&.factory))
  end

  def close
    @server.close
  end

  private def serve(context)
    request = context.request
    response = context.response
    body = request.body || raise "Expected a JSON request body"
    payload = JSON.parse(body)
    response.content_type = "application/json"

    case request.path.split('/').last
    when "auth"
      if payload["password"].as_s == "fixture-password"
        response.print %({"options":{"success":true,"account_id":"test-account"},"user_token":"test-token"})
      else
        response.print %({"options":{"success":false,"message":"Incorrect password"}})
      end
    when "getUserDataForApp"
      if request.headers["ClearBlade-UserToken"]? == "test-token" && payload["resource"]?.try(&.as_s?) == "friedrich"
        response.print location_response
      else
        response.status = HTTP::Status::BAD_REQUEST
      end
    when "dynamicAction"
      @actions << payload
      if payload["usage_type"].as_s == "energyUsage"
        response.print %({"success":true,"results":{"energy_usage":{"data":[{"name":"0","value":0.25},{"name":"1","value":1}],"historyData":[{"name":"0","value":0.5}],"message":"Energy usage in kWh"}}})
      else
        response.print %({"success":true,"results":{"water_usage":{"data":[{"value":2.5},{"value":1}]}}})
      end
    else
      response.status = HTTP::Status::NOT_FOUND
    end
  end
end

class SpecBroker
  DESIRED  = "user/test-account/device/desired"
  REPORTED = "user/test-account/device/reported"

  getter factory : Proc(MQTT::Transport)
  getter connections = Channel(Tuple(TCPSocket, MQTT::V3::Connect, MQTT::V3::Subscribe)).new(1)

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    port = @server.local_address.port
    @factory = -> { MQTT::Transport::TCP.new("127.0.0.1", port).as(MQTT::Transport) }
    spawn do
      while socket = @server.accept?
        socket.read_timeout = 3.seconds
        spawn handshake(socket)
      end
    end
  end

  def close
    @server.close
  end

  def connect
    select
    when connection = connections.receive
      connection
    when timeout(3.seconds)
      raise "Timed out waiting for the local MQTT connection"
    end
  end

  def self.report(socket : TCPSocket, message)
    packet = MQTT::V3::Publish.new
    packet.id = MQTT::RequestType::Publish
    packet.topic = REPORTED
    packet.payload = message.to_json
    packet.packet_length = packet.calculate_length
    socket.write_bytes(packet)
    socket.flush
  end

  def self.next_command(socket : TCPSocket) : JSON::Any
    packet = socket.read_bytes(MQTT::V3::Publish)
    packet.id.should eq(MQTT::RequestType::Publish)
    packet.topic.should eq(DESIRED)
    JSON.parse(String.new(packet.payload))
  end

  private def handshake(socket : TCPSocket)
    connect = socket.read_bytes(MQTT::V3::Connect)
    socket.write(Bytes[0x20, 0x02, 0x00, 0x00])

    subscribe = socket.read_bytes(MQTT::V3::Subscribe)
    suback = MQTT::V3::Suback.new
    suback.id = MQTT::RequestType::Suback
    suback.message_id = subscribe.message_id
    suback.raw_return_codes = Array.new(subscribe.topics.size, 0_u8)
    suback.packet_length = suback.calculate_length
    socket.write_bytes(suback)
    socket.flush
    connections.send({socket, connect, subscribe})
  rescue ex
    socket.close
    raise ex
  end
end

def wait_for_update(channel : Channel(Nil))
  select
  when channel.receive
  when timeout(3.seconds)
    raise "Timed out waiting for an equipment update"
  end
end
