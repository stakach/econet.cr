# EcoNet for Crystal

A Crystal port of [pyeconet](https://github.com/w1ll1am23/pyeconet) v0.3.1 for the unofficial Rheem EcoNet API. It discovers water heaters, thermostats, and thermostat zones over HTTPS and uses [crystal-mqtt](https://github.com/spider-gazelle/crystal-mqtt) for live state updates and device commands.

## Install

Add the shard to your application's `shard.yml`, then run `shards install`. Requires Crystal 1.20 or later.

```yaml
dependencies:
  econet:
    github: stakach/econet.cr
```

## Discover equipment

```crystal
require "econet"

client = EcoNet::Client.login(ENV["ECONET_EMAIL"], ENV["ECONET_PASSWORD"])

client.get_equipment.each do |equipment|
  puts "#{equipment.device_name} (#{equipment.type})"
  case equipment
  when EcoNet::WaterHeater
    puts "Target temperature: #{equipment.set_point_celsius} °C"
    if usage = equipment.get_energy_usage
      puts "Today's usage: #{usage.values.sum} #{equipment.energy_type}"
    end
  when EcoNet::Thermostat
    puts "Mode: #{equipment.mode}"
  end
end
```

Call `refresh_equipment` to fetch fresh state while keeping existing equipment objects and their callbacks. Devices expose supported modes and capabilities, such as away mode, schedule status, fan controls, and leak or shutoff valve information. Availability depends on the model. Water heaters also expose water and historical energy usage where the service provides it.

## Subscribe and send commands

```crystal
heater = client.get_equipment.find { |item| item.is_a?(EcoNet::WaterHeater) }
if heater.is_a?(EcoNet::WaterHeater)
  heater.set_update_callback do
    puts "Updated water-heater set point: #{heater.set_point_celsius} °C"
  end

  if client.subscribe
    begin
      heater.set_point_celsius = 58
      sleep 5.seconds
    ensure
      client.unsubscribe
    end
  end
end
```

`subscribe` waits for the broker and starts processing updates in the background. It returns `false` if equipment has yet to be discovered or none is available. While the subscription is open, the MQTT client reconnects after a dropped connection.

`set_set_point` accepts native API units. Assigning to `set_point_celsius` converts to the water heater's native temperature unit and rounds to the device's reported precision. The Celsius setter raises `ArgumentError` for invalid targets or targets outside the reported limits. Command methods return `true` when a command was sent and `false` when it falls outside reported limits or the device lacks the capability. Read back the reported state to confirm the device applied the command.

The EcoNet cloud endpoints are unofficial and can change independently of this shard.

## Development

```sh
shards install
crystal spec
shards build ameba
bin/ameba
```

The specs exercise REST and MQTT behavior against local servers with fixture data.
