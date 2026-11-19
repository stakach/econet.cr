require "http/client"
require "json"
require "log"
require "mqtt/v3/client"
require "mqtt/transport/tcp"

require "./econet/errors"
require "./econet/equipment"
require "./econet/water_heater"
require "./econet/thermostat"
require "./econet/client"

module EcoNet
  Log = ::Log.for(self)

  alias JsonObject = Hash(String, JSON::Any)
  alias NumericValue = Int64 | Float64
  alias EcoNetApiInterface = Client

  # :nodoc:
  def self.number(value : JSON::Any?) : NumericValue?
    case raw = value.try(&.raw)
    when Int64, Float64 then raw
    when String         then raw.to_i64? || raw.to_f64?
    end
  end

  # :nodoc:
  def self.flag(value : JSON::Any?) : Bool?
    case value.try(&.raw)
    when true, 1, "1", "true"   then true
    when false, 0, "0", "false" then false
    end
  end
end
