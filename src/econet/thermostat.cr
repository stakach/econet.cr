module EcoNet
  enum ThermostatOperationMode
    Off           =  1
    Heating       =  2
    Cooling       =  3
    Auto          =  4
    FanOnly       =  5
    EmergencyHeat =  6
    Unknown       = 99

    def self.by_string(value : String?) : self
      case value.try(&.strip.downcase)
      when "off"             then Off
      when "heating", "heat" then Heating
      when "cooling", "cool" then Cooling
      when "auto"            then Auto
      when "fan only"        then FanOnly
      when "emergency heat"  then EmergencyHeat
      else                        Unknown
      end
    end
  end

  enum ThermostatFanSpeed
    Auto    =  1
    Low     =  2
    MedLo   =  3
    Medium  =  4
    MedHi   =  5
    High    =  6
    Max     =  7
    Unknown = 99

    def self.by_string(value : String?) : self
      case value.try(&.strip.downcase.delete(". "))
      when "auto"   then Auto
      when "low"    then Low
      when "medlo"  then MedLo
      when "medium" then Medium
      when "medhi"  then MedHi
      when "high"   then High
      when "max"    then Max
      else               Unknown
      end
    end
  end

  enum ThermostatFanMode
    Auto         =  1
    OnContinuous =  2
    Unknown      = 99

    def self.by_string(value : String?) : self
      case value.try(&.strip.downcase)
      when "auto"          then Auto
      when "on/continuous" then OnContinuous
      else                      Unknown
      end
    end
  end

  class Thermostat < Equipment
    alias Mode = ThermostatOperationMode
    alias FanSpeed = ThermostatFanSpeed
    alias FanMode = ThermostatFanMode

    def type : EquipmentType
      EquipmentType::Thermostat
    end

    def running? : Bool?
      running_state.try { |state| !state.empty? }
    end

    def running_state : String?
      field("@RUNNINGSTATUS").try(&.as_s?)
    end

    def beep_enabled? : Bool?
      EcoNet.flag(field("@BEEP"))
    end

    def supports_humidifier? : Bool
      !constraints("@DEHUMENABLE").nil?
    end

    def cool_set_point : NumericValue?
      EcoNet.number(field("@COOLSETPOINT"))
    end

    def cool_set_point_limits : Tuple(NumericValue, NumericValue)?
      limits("@COOLSETPOINT")
    end

    def heat_set_point : NumericValue?
      EcoNet.number(field("@HEATSETPOINT"))
    end

    def heat_set_point_limits : Tuple(NumericValue, NumericValue)?
      limits("@HEATSETPOINT")
    end

    def deadband : NumericValue?
      EcoNet.number(field("@DEADBAND"))
    end

    def deadband_set_point_limits : Tuple(NumericValue, NumericValue)?
      limits("@DEADBAND")
    end

    def dehumidifier_set_point : NumericValue?
      EcoNet.number(field("@DEHUMSETPOINT"))
    end

    def dehumidifier_set_point_limits : Tuple(NumericValue, NumericValue)?
      limits("@DEHUMSETPOINT")
    end

    def dehumidifier_enabled? : Bool?
      EcoNet.flag(field("@DEHUMENABLE"))
    end

    def set_dehumidifier_set_point(humidity : Number) : Bool
      return false unless valid_set_point?(humidity, dehumidifier_set_point_limits)
      publish({"@DEHUMSETPOINT" => humidity})
      true
    end

    def zone_id : String?
      field("@ZONE_ID_NAME").try(&.as_s?)
    end

    def humidity : NumericValue?
      EcoNet.number(field("@HUMIDITY"))
    end

    def screen_locked? : Bool?
      EcoNet.flag(field("@SCREENLOCK"))
    end

    def mode : Mode
      Mode.by_string(enum_label("@MODE"))
    end

    def modes : Array(Mode)
      supported_values("@MODE", Mode)
    end

    def set_mode(mode : Mode) : Bool
      set_enum("@MODE", mode)
    end

    def fan_speed : FanSpeed
      FanSpeed.by_string(enum_label("@FANSPEED"))
    end

    def fan_speeds : Array(FanSpeed)
      supported_values("@FANSPEED", FanSpeed)
    end

    def set_fan_speed(speed : FanSpeed) : Bool
      set_enum("@FANSPEED", speed)
    end

    def supports_fan_mode? : Bool
      !raw_field("@FANMODE").try(&.raw).nil?
    end

    def fan_mode : FanMode
      FanMode.by_string(enum_label("@FANMODE"))
    end

    def fan_modes : Array(FanMode)
      supported_values("@FANMODE", FanMode)
    end

    def set_fan_mode(mode : FanMode) : Bool
      set_enum("@FANMODE", mode)
    end

    def set_point_limits : Tuple(NumericValue, NumericValue)?
      case mode
      when .cooling?
        cool_set_point_limits
      when .auto?, .fan_only?
        cool = cool_set_point_limits
        heat = heat_set_point_limits
        {cool[0], heat[1]} if cool && heat
      else
        heat_set_point_limits
      end
    end

    # In auto mode, supply explicit heating and cooling set points.
    # Explicit set points take precedence over the single target.
    def set_set_point(target_temp : Number? = nil, target_temp_cool : Number? = nil, target_temp_heat : Number? = nil) : Bool
      selected = mode
      if target_temp && target_temp_cool.nil? && target_temp_heat.nil?
        case selected
        when .cooling?                   then target_temp_cool = target_temp
        when .heating?, .emergency_heat? then target_temp_heat = target_temp
        end
      end

      sent = false
      if (selected.auto? || selected.cooling?) && (cool = target_temp_cool) && valid_set_point?(cool, cool_set_point_limits)
        publish({"@COOLSETPOINT" => cool})
        sent = true
      end
      if (selected.auto? || selected.heating? || selected.emergency_heat?) && (heat = target_temp_heat) && valid_set_point?(heat, heat_set_point_limits)
        publish({"@HEATSETPOINT" => heat})
        sent = true
      end
      sent
    end

    private def supported_values(key : String, type : T.class) : Array(T) forall T
      enum_labels(key).map { |label| type.by_string(label) }.reject(&.unknown?)
    end

    private def set_enum(key : String, value : T) : Bool forall T
      return false if value.unknown?
      return false unless index = enum_labels(key).index { |label| T.by_string(label) == value }

      publish({key => index})
      true
    end
  end
end
