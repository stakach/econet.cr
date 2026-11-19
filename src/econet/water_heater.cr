module EcoNet
  enum WaterHeaterOperationMode
    Off          =  1
    ElectricMode =  2
    EnergySaving =  3
    HeatPumpOnly =  4
    HighDemand   =  5
    Gas          =  6
    Performance  =  8
    Vacation     =  9
    ElectricGas  = 12
    Unknown      = 99

    def self.by_string(value : String?) : self
      case value.try(&.strip.downcase)
      when "off"                           then Off
      when "electric mode", "electric"     then ElectricMode
      when "energy saving", "energy saver" then EnergySaving
      when "heat pump only", "heat pump"   then HeatPumpOnly
      when "high demand"                   then HighDemand
      when "gas"                           then Gas
      when "performance"                   then Performance
      when "vacation"                      then Vacation
      when "electric/gas"                  then ElectricGas
      else                                      Unknown
      end
    end
  end

  class WaterHeater < Equipment
    alias Mode = WaterHeaterOperationMode

    getter energy_usage : Hash(Int32, Float64)?
    getter historical_energy_usage : Hash(Int32, Float64)?
    getter energy_type : String?
    getter water_usage : Float64?

    def type : EquipmentType
      EquipmentType::WaterHeater
    end

    def leak_installed? : Bool
      EcoNet.flag(field("@LEAKINSTALLED")) == true
    end

    def has_shutoff_valve? : Bool
      valve_title.try(&.starts_with?("Shut-OFF Valve - ")) == true
    end

    def shutoff_valve_open? : Bool?
      case valve_title
      when "Shut-OFF Valve - Open"   then true
      when "Shut-OFF Valve - Closed" then false
      end
    end

    def running? : Bool
      running_state.try { |state| !state.empty? } == true
    end

    def running_state : String?
      field("@RUNNING").try(&.as_s?)
    end

    def tank_hot_water_availability : Int32?
      return unless icon = field("@HOTWATER").try(&.as_s?)

      case icon
      when /ic_tank_hundread_percent/     then 100
      when /ic_tank_fourty_percent/       then 66
      when /ic_tank_ten_percent/          then 33
      when /ic_tank_(empty|zero_percent)/ then 0
      end
    end

    def tank_health : NumericValue?
      EcoNet.number(field("@TANK"))
    end

    def compressor_health : NumericValue?
      EcoNet.number(field("@COMBUSTION"))
    end

    def demand_response_over? : Bool?
      EcoNet.flag(field("@VALVE")).try { |active| !active }
    end

    def supports_modes? : Bool
      !raw_field("@MODE").try(&.raw).nil?
    end

    def supports_on_off? : Bool
      !raw_field("@ENABLED").try(&.raw).nil?
    end

    def modes : Array(Mode)
      available = enum_labels("@MODE").map { |label| mode_for(label) }.reject(&.unknown?)
      if supports_on_off?
        available << default_mode if available.empty?
        available << Mode::Off unless available.includes?(Mode::Off)
      end
      available
    end

    def mode : Mode
      return Mode::Off if supports_on_off? && enabled? == false
      supports_modes? ? mode_for(enum_label("@MODE")) : default_mode
    end

    def enabled? : Bool?
      return EcoNet.flag(field("@ENABLED")) if supports_on_off?
      if supports_modes?
        selected = mode_for(enum_label("@MODE"))
        return !selected.off? unless selected.unknown?
      end
      nil
    end

    def override_status : String?
      field("@OVERRIDESTATUS").try(&.as_s?)
    end

    def set_mode(new_mode : Mode) : Bool # ameba:disable Naming/AccessorMethodName
      return false unless modes.includes?(new_mode)

      payload = {} of String => Int32
      payload["@ENABLED"] = new_mode.off? ? 0 : 1 if supports_on_off?
      if index = enum_labels("@MODE").index { |label| mode_for(label) == new_mode }
        payload["@MODE"] = index
      end
      return false if payload.empty?

      publish(payload)
      true
    end

    # Send a set point in the units reported by the equipment's API.
    def set_set_point(target : Number) : Bool # ameba:disable Naming/AccessorMethodName
      return false unless valid_set_point?(target, set_point_limits)
      publish({"@SETPOINT" => target})
      true
    end

    # EcoNet water heaters typically report whole degrees Fahrenheit.
    def set_point_celsius : Float64?
      if target = set_point
        celsius_set_points? ? target.to_f64 : (target - 32) * 5.0 / 9.0
      end
    end

    # Convert to the device's native units and round to its reported precision.
    # Raises `ArgumentError` if the target is invalid or outside the reported limits.
    def set_point_celsius=(target : Number) : Nil
      raise ArgumentError.new("Celsius set point must be finite") unless target.to_f64.finite?

      native = celsius_set_points? ? target.to_f64 : target * 9.0 / 5.0 + 32
      decimals = EcoNet.number(constraints("@SETPOINT").try(&.["formatDecimal"]?)) || 0
      precision = decimals.clamp(0, 6).to_i
      rounded = native.round(precision)
      value = precision.zero? && rounded.abs < Int64::MAX ? rounded.to_i64 : rounded
      unless set_set_point(value)
        raise ArgumentError.new("Celsius set point #{target} is outside the water heater's reported limits")
      end
    end

    def todays_energy_usage : Float64?
      usage = energy_usage
      usage.values.sum unless usage.nil? || usage.empty?
    end

    def todays_water_usage : Float64?
      water_usage
    end

    # Fetch and store hourly energy usage for the requested interval.
    # Defaults to today in the caller's local time zone.
    def get_energy_usage(start : Time? = nil, end_time : Time? = nil) : Hash(Int32, Float64)?
      report = usage_report("energyUsage", "energy_usage", start, end_time, offset: true)
      return unless report

      current = usage_data(report, "data")
      history = usage_data(report, "historyData")
      unit = report["message"]?.try(&.as_s?).try(&.split[3]?).try(&.upcase)
      @historical_energy_usage = history
      @energy_type = unit || (gas? ? "KBTU" : "KWH")
      @energy_usage = current
    end

    def get_water_usage(start : Time? = nil, end_time : Time? = nil) : Float64?
      report = usage_report("waterUsage", "water_usage", start, end_time, offset: false)
      return unless report

      readings = report["data"]?.try(&.as_a?)
      raise InvalidResponseFormat.new("Missing water usage data") unless readings
      total = readings.sum do |reading|
        EcoNet.number(reading.as_h?.try(&.["value"]?)).try(&.to_f64) ||
          raise InvalidResponseFormat.new("Invalid water usage reading")
      end
      @water_usage = total
    end

    private def valve_title : String?
      raw_field("@VALVESTATUS").try(&.as_h?).try(&.["title"]?).try(&.as_s?)
    end

    private def gas? : Bool
      generic_type.in?("gasWaterHeater", "tanklessWaterHeater")
    end

    private def default_mode : Mode
      gas? ? Mode::Gas : Mode::ElectricMode
    end

    private def mode_for(label : String?) : Mode
      candidate = Mode.by_string(label)
      candidate.electric_gas? ? default_mode : candidate
    end

    private def celsius_set_points? : Bool
      unit = constraints("@SETPOINT").try(&.["units"]?).try(&.as_s?)
      unit.try(&.strip.downcase).in?("deg c", "°c", "c", "celsius")
    end

    private def usage_report(kind : String, key : String, start : Time?, end_time : Time?, offset : Bool) : JsonObject?
      today = Time.local
      date = today.at_beginning_of_day
      start ||= date + 999.milliseconds
      end_time ||= date.shift(days: 1) - 1.millisecond
      format = offset ? "%Y-%m-%dT%H:%M:%S.%L%:z" : "%Y-%m-%dT%H:%M:%S.%L"

      response = @api.get_dynamic_action({
        "ACTION"        => "waterheaterUsageReportView",
        "device_name"   => device_id,
        "serial_number" => serial_number,
        "start_date"    => start.to_s(format),
        "end_date"      => end_time.to_s(format),
        "usage_type"    => kind,
      })
      response["results"]?.try(&.as_h?).try(&.[key]?).try(&.as_h?)
    rescue InvalidResponseFormat
      nil
    end

    private def usage_data(report : JsonObject, key : String) : Hash(Int32, Float64)
      data = report[key]?.try(&.as_a?)
      raise InvalidResponseFormat.new("Missing energy usage #{key}") unless data

      readings = {} of Int32 => Float64
      data.each do |item|
        fields = item.as_h?
        period = EcoNet.number(fields.try(&.["name"]?))
        value = EcoNet.number(fields.try(&.["value"]?))
        unless period && Int32::MIN <= period <= Int32::MAX && period == period.trunc && value
          raise InvalidResponseFormat.new("Invalid energy usage reading")
        end
        readings[period.to_i32] = value.to_f64
      end
      readings
    end
  end
end
