module EcoNet
  class Client
    DEFAULT_HOST = "rheem.rheemconnect.com"
    REST_URL     = "https://#{DEFAULT_HOST}/api/v/1"
    MQTT_PORT    = 1884

    # ClearBlade application identifiers used by the EcoNet mobile client.
    private SYSTEM_KEY    = "e2e699cb0bb0bbb88fc8858cb5a401"
    private SYSTEM_SECRET = "E2E699CB0BE6C6FADDB1B0BC9A20"

    getter account_id : String
    getter user_token : String

    @equipment = {} of String => Equipment
    @equipment_lock = Mutex.new
    @subscription_lock = Mutex.new
    @mqtt_client : MQTT::V3::Client? = nil

    # Open an existing authenticated session. The user token is the token
    # returned by EcoNet authentication.
    def initialize(
      @email : String,
      @account_id : String,
      @user_token : String,
      @rest_url : String = REST_URL,
      @mqtt_transport : Proc(MQTT::Transport)? = nil,
    )
    end

    # Authenticate with EcoNet. The password is used only for this request.
    def self.login(
      email : String,
      password : String,
      *,
      rest_url : String = REST_URL,
      mqtt_transport : Proc(MQTT::Transport)? = nil,
    ) : self
      response = request(rest_url, "/user/auth", {email: email, password: password}.to_json)
      options = response["options"]?.try(&.as_h?)
      success = options.try(&.["success"]?).try(&.as_bool?)
      raise InvalidResponseFormat.new("Missing EcoNet authentication status") if success.nil?
      raise InvalidCredentialsError.new("EcoNet rejected the account credentials") unless success

      account_id = options.try(&.["account_id"]?).try(&.as_s?)
      token = response["user_token"]?.try(&.as_s?)
      if account_id.nil? || account_id.empty? || token.nil? || token.empty?
        raise InvalidResponseFormat.new("Missing EcoNet account ID or user token")
      end
      new(email, account_id, token, rest_url, mqtt_transport)
    rescue error : GenericHTTPError
      if error.status_code.in?(401, 403)
        raise InvalidCredentialsError.new("EcoNet rejected the account credentials")
      end
      raise error
    end

    # Avoid including the session token or other account details in inspection.
    def inspect(io : IO) : Nil
      io << "#<" << self.class << ">"
    end

    # Discover equipment and reuse the same objects on subsequent calls.
    def get_equipment : Array(Equipment) # ameba:disable Naming/AccessorMethodName
      equipment = @equipment_lock.synchronize { @equipment.values }
      equipment.empty? ? refresh_equipment : equipment
    end

    def get_equipment_by_type(types : Enumerable(EquipmentType)) : Hash(EquipmentType, Array(Equipment))
      groups = {} of EquipmentType => Array(Equipment)
      types.each { |type| groups[type] = [] of Equipment }
      get_equipment.each { |equipment| groups[equipment.type]?.try &.push(equipment) }
      groups
    end

    # Discover new devices and update the state of existing devices and zones.
    def refresh_equipment : Array(Equipment)
      response = successful_request("getUserDataForApp", {resource: "friedrich"}.to_json)
      locations = response["results"]?.try(&.as_h?).try(&.["locations"]?).try(&.as_a?)
      raise InvalidResponseFormat.new("Missing EcoNet locations") unless locations

      locations.each do |location|
        location.as_h?.try(&.["equiptments"]?).try(&.as_a?).try &.each do |entry|
          if info = entry.as_h?
            next if info.has_key?("error")
            case EquipmentType.from_device_type(info["device_type"]?.try(&.as_s?))
            when .water_heater?
              register(WaterHeater, info)
            when .thermostat?
              register(Thermostat, info)
              info["zoning_devices"]?.try(&.as_a?).try &.each do |zone|
                if zone_info = zone.as_h?
                  register(Thermostat, zone_info, parent: info)
                end
              end
            end
          end
        end
      end
      @equipment_lock.synchronize { @equipment.values }
    end

    def get_dynamic_action(payload) : JSON::Any
      successful_request("dynamicAction", payload.to_json)
    end

    # Connect and subscribe to the account's reported and desired topics.
    # Returns false if there is no discovered equipment to track.
    def subscribe : Bool
      return false if @equipment_lock.synchronize { @equipment.empty? }

      @subscription_lock.synchronize do
        return true if @mqtt_client.try { |client| !client.terminated? }

        mqtt = open_mqtt
        begin
          mqtt.connect(
            username: @user_token,
            password: SYSTEM_KEY,
            # Allow a second keepalive check before the 75-second socket read timeout.
            keep_alive: 30,
            client_id: "#{@email}#{Time.utc.to_unix_ms}_android",
          ).success!

          callback = ->(_topic : String, payload : Bytes) { handle_message(String.new(payload)) }
          topics = {} of String => Tuple(MQTT::QoS, MQTT::V3::Client::Callback)
          topics[desired_topic] = {MQTT::QoS::FireAndForget, callback}
          topics["user/#{@account_id}/device/reported"] = {MQTT::QoS::FireAndForget, callback}
          mqtt.subscribe(topics)
          @mqtt_client = mqtt
        rescue error
          mqtt.disconnect(false)
          raise error
        end
      end
      true
    rescue error : MQTT::Error
      raise ConnectionError.new("Could not subscribe to EcoNet MQTT", error)
    end

    def subscribed? : Bool
      @mqtt_client.try { |client| !client.closed? } || false
    end

    def unsubscribe : Nil
      @subscription_lock.synchronize do
        mqtt = @mqtt_client
        @mqtt_client = nil
        mqtt.try &.disconnect
      end
    end

    # Send a desired state update using the device's API field names and units.
    def publish(payload, device_id : String, serial_number : String) : Nil
      mqtt = @mqtt_client
      raise ConnectionError.new("Subscribe to EcoNet MQTT before publishing") if mqtt.nil? || mqtt.closed?

      message = JSON.build do |json|
        json.object do
          json.field "transactionId", "ANDROID_#{Time.local.to_s("%Y-%m-%dT%H:%M:%S")}"
          json.field "device_name", device_id
          json.field "serial_number", serial_number
          payload.each do |key, value|
            next if key.in?("transactionId", "device_name", "serial_number")
            json.field key, value
          end
        end
      end
      mqtt.publish(desired_topic, message)
    rescue error : MQTT::Error
      raise ConnectionError.new("Could not publish the EcoNet MQTT command", error)
    end

    private def register(model : T.class, info : JsonObject, parent : JsonObject? = nil) : Nil forall T
      return if info.has_key?("error")
      serial = info["serial_number"]?.try(&.as_s?)
      device = info["device_name"]?.try(&.as_s?) || parent.try(&.["device_name"]?).try(&.as_s?)
      return if serial.nil? || serial.empty? || device.nil? || device.empty?

      existing = @equipment_lock.synchronize do
        if equipment = @equipment[serial]?
          equipment
        else
          info = info.dup
          info["device_name"] = JSON::Any.new(device)
          @equipment[serial] = model.new(info, self)
          nil
        end
      end
      existing.try &.update_equipment_info(info, device)
    end

    private def open_mqtt : MQTT::V3::Client
      factory = @mqtt_transport || -> {
        context = OpenSSL::SSL::Context::Client.new
        MQTT::Transport::TCP.new(DEFAULT_HOST, MQTT_PORT, context, read_timeout: 75, write_timeout: 15).as(MQTT::Transport)
      }
      MQTT::V3::Client.new(&factory)
    end

    private def desired_topic : String
      "user/#{@account_id}/device/desired"
    end

    private def handle_message(payload : String) : Nil
      update = JSON.parse(payload).as_h?
      return unless update

      serial = update["serial_number"]?.try(&.as_s?)
      device = update["device_name"]?.try(&.as_s?)
      targets = @equipment_lock.synchronize do
        if serial && (equipment = @equipment[serial]?)
          [equipment]
        elsif device && update.has_key?("@SIGNAL")
          @equipment.values.select { |item| item.device_id == device }
        else
          [] of Equipment
        end
      end
      targets.each &.update_equipment_info(update, device)
    rescue error : JSON::ParseException | EcoNet::Error
      Log.debug { "Ignoring an EcoNet MQTT update (#{error.class})" }
    end

    private def successful_request(action : String, payload : String) : JSON::Any
      response = self.class.request(@rest_url, "/code/#{SYSTEM_KEY}/#{action}", payload, @user_token)
      unless response["success"]?.try(&.as_bool?) == true
        raise InvalidResponseFormat.new("EcoNet did not return a successful #{action} response")
      end
      response
    end

    protected def self.request(base_url : String, path : String, payload : String, token : String? = nil) : JSON::Any
      uri = URI.parse(base_url.rstrip('/') + path)
      headers = HTTP::Headers{
        "ClearBlade-SystemKey"    => SYSTEM_KEY,
        "ClearBlade-SystemSecret" => SYSTEM_SECRET,
        "Content-Type"            => "application/json; charset=UTF-8",
      }
      headers["ClearBlade-UserToken"] = token if token

      response = HTTP::Client.new(uri) do |http|
        http.connect_timeout = 10.seconds
        http.read_timeout = 15.seconds
        http.write_timeout = 15.seconds
        http.post(uri.request_target, headers: headers, body: payload)
      end
      raise GenericHTTPError.new(response.status_code) unless response.status.ok?

      decoded = JSON.parse(response.body)
      raise InvalidResponseFormat.new("Expected an EcoNet JSON object") unless decoded.as_h?
      decoded
    rescue JSON::ParseException
      raise InvalidResponseFormat.new("EcoNet returned invalid JSON")
    rescue error : IO::Error | Socket::Error | OpenSSL::Error
      raise ConnectionError.new("Could not reach the EcoNet HTTP API", error)
    end
  end
end
