module EcoNet
  enum EquipmentType
    WaterHeater =  1
    Thermostat  =  2
    Unknown     = 99

    def self.from_device_type(value : String?) : self
      case value
      when "WH"   then WaterHeater
      when "HVAC" then Thermostat
      else             Unknown
      end
    end
  end

  abstract class Equipment
    getter device_id : String
    getter serial_number : String
    @update_callback : Proc(Nil)? = nil
    @resume_confirmation_deadline : MQTT::Monotonic? = nil

    def initialize(@info : JsonObject, @api : Client)
      @device_id = @info["device_name"].as_s
      @serial_number = @info["serial_number"].as_s
    end

    abstract def type : EquipmentType

    def set_update_callback(&callback : -> Nil) : Nil
      @update_callback = callback
    end

    def set_update_callback(callback : Proc(Nil)?) : Nil
      @update_callback = callback
    end

    def update_equipment_info(update : JsonObject, device : String? = update["device_name"]?.try(&.as_s?)) : Nil
      return unless device == device_id

      if dialog = update["dialog"]?.try(&.as_h?)
        confirm_resume(dialog)
        return
      end

      changed = false
      update.each do |key, incoming|
        next unless key.starts_with?('@')

        if previous = raw_field(key).try(&.as_h?)
          if fields = incoming.as_h?
            previous.delete("status") if fields.has_key?("value") && !fields.has_key?("status")
            previous.merge!(fields)
          else
            previous.delete("status")
            previous["value"] = incoming
          end
        else
          @info[key] = incoming
        end
        changed = true
      end

      if following_schedule?
        @resume_confirmation_deadline = nil
      end

      if changed && (callback = @update_callback)
        spawn do
          callback.call
        rescue error
          Log.warn { "EcoNet equipment update callback failed (#{error.class})" }
        end
      end
    end

    def device_name : String
      field("@NAME").try(&.as_s?) || device_id
    end

    def generic_type : String?
      field("@TYPE").try(&.as_s?)
    end

    def active? : Bool
      EcoNet.flag(field("@ACTIVE")) != false
    end

    def connected? : Bool
      EcoNet.flag(field("@CONNECTED")) != false
    end

    def supports_away? : Bool
      EcoNet.flag(field("@AWAYCONFIG")) == true || @info.has_key?("@AWAY")
    end

    def away? : Bool
      EcoNet.flag(field("@AWAY")) == true
    end

    def vacation? : Bool?
      EcoNet.flag(field("@VACATION"))
    end

    def supports_schedule? : Bool
      @info.has_key?("@SCHEDULESTATUS")
    end

    def schedule_status : String?
      field("@SCHEDULESTATUS").try(&.as_s?)
    end

    def following_schedule? : Bool
      schedule_status == "Following Schedule"
    end

    def alert_count : Int64?
      EcoNet.number(field("@ALERTCOUNT")).try(&.to_i64)
    end

    def set_point : NumericValue?
      EcoNet.number(field("@SETPOINT"))
    end

    def set_point_limits : Tuple(NumericValue, NumericValue)?
      limits("@SETPOINT")
    end

    def wifi_signal : Int64?
      EcoNet.number(field("@SIGNAL")).try(&.to_i64)
    end

    def force_update_from_api : Nil
      @api.refresh_equipment
    end

    def set_away_mode(away : Bool) : Bool
      return false unless supports_away?
      publish({"@AWAY" => away})
      true
    end

    def resume_schedule : Bool
      return false unless supports_schedule?

      deadline = MQTT.monotonic + 30.seconds
      @resume_confirmation_deadline = deadline
      begin
        publish({"@SCHEDULERESUME" => "resume"})
      rescue error
        @resume_confirmation_deadline = nil if @resume_confirmation_deadline == deadline
        raise error
      end
      true
    end

    protected def publish(payload) : Nil
      @api.publish(payload, device_id, serial_number)
    end

    protected def raw_field(key : String) : JSON::Any?
      @info[key]?
    end

    protected def field(key : String) : JSON::Any?
      raw = raw_field(key)
      fields = raw.try(&.as_h?)
      fields ? fields["value"]? : raw
    end

    protected def constraints(key : String) : JsonObject?
      raw_field(key).try(&.as_h?).try(&.["constraints"]?).try(&.as_h?)
    end

    protected def limits(key : String) : Tuple(NumericValue, NumericValue)?
      bounds = constraints(key)
      lower = EcoNet.number(bounds.try(&.["lowerLimit"]?))
      upper = EcoNet.number(bounds.try(&.["upperLimit"]?))
      {lower, upper} if lower && upper
    end

    protected def enum_labels(key : String) : Array(String?)
      values = constraints(key).try(&.["enumText"]?).try(&.as_a?)
      values ? values.map(&.as_s?) : [] of String?
    end

    protected def enum_index(key : String) : Int32?
      if key == "@MODE"
        status = raw_field(key).try(&.as_h?).try(&.["status"]?).try(&.as_s?).try(&.strip)
        if status && !status.empty?
          index = enum_labels(key).index { |label| label.try(&.strip) == status }
          return index if index
        end
      end
      index = EcoNet.number(field(key))
      index.to_i32 if index && 0 <= index <= Int32::MAX && index == index.trunc
    end

    protected def enum_label(key : String) : String?
      if index = enum_index(key)
        enum_labels(key)[index]?
      end
    end

    protected def valid_set_point?(value : Number, bounds : Tuple(NumericValue, NumericValue)?) : Bool
      !!(bounds && bounds[0] <= value <= bounds[1])
    end

    private def confirm_resume(dialog : JsonObject) : Nil
      deadline = @resume_confirmation_deadline
      return unless deadline && MQTT.monotonic <= deadline
      message = dialog["message"]?.try(&.as_h?)
      return unless message && !message.empty?

      @resume_confirmation_deadline = nil
      publish(message)
    end
  end
end
