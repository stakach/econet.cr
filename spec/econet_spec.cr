require "./spec_helper"

describe EcoNet::Client do
  it "authenticates, groups the discovered equipment, and refreshes existing zones" do
    cloud = SpecCloud.new
    client = cloud.login
    client.inspect.should_not contain("test-token")
    client.account_id.should eq("test-account")
    client.subscribe.should be_false

    types = [EcoNet::EquipmentType::WaterHeater, EcoNet::EquipmentType::Thermostat, EcoNet::EquipmentType::Unknown]
    equipment = client.get_equipment_by_type(types)
    equipment.transform_values(&.size).values.should eq([2, 2, 0])
    zone = equipment[EcoNet::EquipmentType::Thermostat].last.as(EcoNet::Thermostat)
    zone.device_id.should eq("hvac")
    zone.zone_id.should eq("Zone 1")
    zone.schedule_status.should be_nil

    cloud.location_response = SpecCloud::LOCATION_RESPONSE.sub("Zone 1", "Upstairs")
    zone.force_update_from_api
    client.get_equipment.last.should be(zone)
    zone.zone_id.should eq("Upstairs")
  ensure
    cloud.try &.close
  end

  it "rejects bad credentials and malformed API responses with typed errors" do
    cloud = SpecCloud.new
    expect_raises(EcoNet::InvalidCredentialsError) do
      EcoNet::Client.login("test@example.invalid", "wrong", rest_url: cloud.url)
    end
    client = cloud.login
    cloud.location_response = %({"success":true,"results":[]})
    expect_raises(EcoNet::InvalidResponseFormat) { client.get_equipment }
    cloud.location_response = %({"success":true,"results":{"locations":[]}})
    client.get_equipment.should be_empty
  ensure
    cloud.try &.close
  end

  it "fetches usage reports, honoring both requested dates" do
    cloud = SpecCloud.new
    heater = cloud.login.get_equipment.first.as(EcoNet::WaterHeater)
    start = Time.utc(2025, 4, 27, 10, 30)
    finish = start + 2.hours

    heater.get_energy_usage(start, finish).should eq({0 => 0.25, 1 => 1.0})
    heater.historical_energy_usage.should eq({0 => 0.5})
    heater.energy_type.should eq("KWH")
    heater.todays_energy_usage.should eq(1.25)
    cloud.actions[0]["ACTION"].should eq("waterheaterUsageReportView")
    cloud.actions[0]["start_date"].should eq("2025-04-27T10:30:00.000+00:00")
    cloud.actions[0]["end_date"].should eq("2025-04-27T12:30:00.000+00:00")

    heater.get_water_usage(start, finish).should eq(3.5)
    heater.todays_water_usage.should eq(3.5)
    cloud.actions[1]["usage_type"].should eq("waterUsage")
    cloud.actions[1]["start_date"].should eq("2025-04-27T10:30:00.000")
    cloud.actions[1]["end_date"].should eq("2025-04-27T12:30:00.000")
  ensure
    cloud.try &.close
  end

  it "applies MQTT updates and writes validated set points and equipment modes" do
    cloud = SpecCloud.new
    broker = SpecBroker.new
    client = cloud.login(broker)
    equipment = client.get_equipment
    heater = equipment[0].as(EcoNet::WaterHeater)
    gas = equipment[1].as(EcoNet::WaterHeater)
    thermostat = equipment[2].as(EcoNet::Thermostat)
    zone = equipment[3]
    heater.mode.should eq(EcoNet::WaterHeater::Mode::HeatPumpOnly)
    heater.modes.count(&.off?).should eq(1)
    heater.supports_away?.should be_true
    thermostat.mode.should eq(EcoNet::Thermostat::Mode::EmergencyHeat)
    thermostat.fan_speed.should eq(EcoNet::Thermostat::FanSpeed::MedHi)
    gas.mode.should eq(EcoNet::WaterHeater::Mode::Gas)
    gas.enabled?.should be_nil
    celsius = heater.set_point_celsius || raise "Expected a Celsius set point"
    celsius.should be_close(57.78, 0.01)
    gas.set_point_celsius.should eq(49.0)
    gas.set_point_limits_celsius.should eq({45.0, 60.0})
    expect_raises(EcoNet::ConnectionError) { heater.set_set_point(136) }
    expect_raises(EcoNet::ConnectionError) { heater.set_point = 136 }

    client.subscribe.should be_true
    client.subscribed?.should be_true
    socket, connect, subscribe = broker.connect
    connect.username.should eq("test-token")
    connect.version.should eq(MQTT::Version::V311)
    connect.keep_alive_seconds.should eq(30)
    subscribe.topic_hash.keys.sort!.should eq([SpecBroker::DESIRED, SpecBroker::REPORTED])
    client.subscribe.should be_true

    heater.set_set_point(200).should be_false
    expect_raises(ArgumentError) { heater.set_point = 200 }
    expect_raises(ArgumentError) { heater.set_point_celsius = 200 }
    expect_raises(ArgumentError) { heater.set_point_celsius = Float64::NAN }
    heater.set_point_celsius = 58
    desired = SpecBroker.next_command(socket)
    desired["device_name"].should eq("heater")
    desired["serial_number"].should eq("heater-1")
    desired["transactionId"].as_s.should start_with("ANDROID_")
    desired["@SETPOINT"].should eq(136)
    heater.set_point_celsius = 59
    SpecBroker.next_command(socket)["@SETPOINT"].should eq(138)
    gas.set_point_celsius = 51.26
    SpecBroker.next_command(socket)["@SETPOINT"].should eq(51.3)
    heater.set_point = 137
    SpecBroker.next_command(socket)["@SETPOINT"].should eq(137)
    heater.set_point.should eq(136)
    expect_raises(ArgumentError) { heater.mode = EcoNet::WaterHeater::Mode::Gas }
    heater.mode = EcoNet::WaterHeater::Mode::ElectricMode
    desired = SpecBroker.next_command(socket)
    desired["@MODE"].should eq(3)
    desired["@ENABLED"].should eq(1)
    expect_raises(ArgumentError) { gas.away = true }
    heater.away = true
    SpecBroker.next_command(socket)["@AWAY"].as_bool.should be_true

    heater_updates = Channel(Nil).new(1)
    heater.on_update { heater_updates.send(nil) }
    SpecBroker.report(socket, {
      "device_name" => "heater", "serial_number" => "heater-1",
      "@SETPOINT" => 138, "@ENABLED" => 0, "@RUNNING" => "Heating", "@HOTWATER" => "ic_tank_fourty_percent.png",
    })
    wait_for_update(heater_updates)
    heater.set_point.should eq(138)
    heater.set_point_limits.should eq({110, 140})
    heater.enabled?.should be_false
    heater.mode.should eq(EcoNet::WaterHeater::Mode::Off)
    heater.running?.should be_true
    heater.tank_hot_water_availability.should eq(66)

    thermostat_updates = Channel(Nil).new(1)
    thermostat.on_update { thermostat_updates.send(nil) }
    SpecBroker.report(socket, {"device_name" => "hvac", "serial_number" => "hvac-1", "@MODE" => 2})
    wait_for_update(thermostat_updates)
    thermostat.mode.should eq(EcoNet::Thermostat::Mode::Cooling)
    thermostat.set_set_point(77).should be_true
    SpecBroker.next_command(socket)["@COOLSETPOINT"].should eq(77)
    expect_raises(ArgumentError) { thermostat.heat_set_point = 66 }
    expect_raises(ArgumentError) { thermostat.cool_set_point = 100 }
    thermostat.cool_set_point = 78
    SpecBroker.next_command(socket)["@COOLSETPOINT"].should eq(78)
    expect_raises(ArgumentError) { thermostat.mode = EcoNet::Thermostat::Mode::Unknown }
    thermostat.mode = EcoNet::Thermostat::Mode::Auto
    SpecBroker.next_command(socket)["@MODE"].should eq(3)
    SpecBroker.report(socket, {"device_name" => "hvac", "serial_number" => "hvac-1", "@MODE" => {"value" => 3}})
    wait_for_update(thermostat_updates)
    thermostat.heat_set_point = 67
    SpecBroker.next_command(socket)["@HEATSETPOINT"].should eq(67)
    thermostat.set_set_point(70, target_temp_cool: 78, target_temp_heat: 66).should be_true
    SpecBroker.next_command(socket)["@COOLSETPOINT"].should eq(78)
    SpecBroker.next_command(socket)["@HEATSETPOINT"].should eq(66)
    thermostat.set_fan_speed(EcoNet::Thermostat::FanSpeed::High).should be_false
    expect_raises(ArgumentError) { thermostat.fan_speed = EcoNet::Thermostat::FanSpeed::High }
    thermostat.fan_speed = EcoNet::Thermostat::FanSpeed::Low
    SpecBroker.next_command(socket)["@FANSPEED"].should eq(1)
    thermostat.fan_mode = EcoNet::Thermostat::FanMode::OnContinuous
    SpecBroker.next_command(socket)["@FANMODE"].should eq(1)
    expect_raises(ArgumentError) { thermostat.dehumidifier_set_point = 90 }
    thermostat.dehumidifier_set_point = 55
    SpecBroker.next_command(socket)["@DEHUMSETPOINT"].should eq(55)

    zone_updates = Channel(Nil).new(1)
    zone.set_update_callback { zone_updates.send(nil) }
    SpecBroker.report(socket, {"device_name" => "hvac", "@SIGNAL" => "-67"})
    wait_for_update(zone_updates)
    thermostat.wifi_signal.should eq(-67)
    zone.wifi_signal.should eq(-67)

    gas_updates = Channel(Nil).new(1)
    gas.on_update { gas_updates.send(nil) }
    SpecBroker.report(socket, {
      "device_name"   => "gas-heater",
      "serial_number" => "heater-2",
      "@MODE"         => {"value" => 0, "constraints" => {"enumText" => ["Electric/Gas  "]}},
    })
    wait_for_update(gas_updates)
    gas.modes.should eq([EcoNet::WaterHeater::Mode::Gas])
    gas.mode = EcoNet::WaterHeater::Mode::Gas
    SpecBroker.next_command(socket)["@MODE"].should eq(0)

    SpecBroker.report(socket, {
      "device_name"   => "heater",
      "serial_number" => "heater-1",
      "@MODE"         => {"value" => 1, "constraints" => {"enumText" => ["Off/Disabled", "Default", "Off Peak", "Solar", "Holiday"]}},
      "@RUNNING"      => "Not Running",
      "@ENABLED"      => 1,
    })
    wait_for_update(heater_updates)
    heater.mode.should eq(EcoNet::WaterHeater::Mode::Default)
    heater.running?.should be_false
    heater.set_point_limits_celsius.try(&.[1]).should eq(60.0)
    heater.mode = EcoNet::WaterHeater::Mode::Vacation
    SpecBroker.next_command(socket)["@MODE"].should eq(4)

    client.unsubscribe
    client.subscribed?.should be_false
    socket.read_bytes(MQTT::V3::Header).id.should eq(MQTT::RequestType::Disconnect)
  ensure
    client.try &.unsubscribe
    socket.try &.close
    broker.try &.close
    cloud.try &.close
  end

  it "confirms a device dialog once after the caller requests schedule resume" do
    cloud = SpecCloud.new
    broker = SpecBroker.new
    client = cloud.login(broker)
    heater = client.get_equipment.first.as(EcoNet::WaterHeater)
    heater.schedule_status.should eq(EcoNet::ScheduleStatus::Overridden)
    heater.following_schedule?.should be_false
    client.subscribe
    socket = broker.connect[0]

    dialog = {"device_name" => "heater", "serial_number" => "heater-1", "dialog" => {"message" => {"@SCHEDULERESUME" => "resume"}}}
    updates = Channel(Nil).new(1)
    heater.on_update { updates.send(nil) }
    SpecBroker.report(socket, dialog)
    SpecBroker.report(socket, {"device_name" => "heater", "serial_number" => "heater-1", "@AWAY" => true})
    wait_for_update(updates)
    socket.read_timeout = 50.milliseconds
    expect_raises(IO::TimeoutError) { socket.read_byte }
    socket.read_timeout = 3.seconds

    heater.resume_schedule.should be_true
    SpecBroker.next_command(socket)["@SCHEDULERESUME"].should eq("resume")
    SpecBroker.report(socket, dialog)
    SpecBroker.next_command(socket)["@SCHEDULERESUME"].should eq("resume")
    SpecBroker.report(socket, dialog)

    SpecBroker.report(socket, {"device_name" => "heater", "serial_number" => "heater-1", "@SCHEDULESTATUS" => "Following Schedule"})
    wait_for_update(updates)
    heater.schedule_status.should eq(EcoNet::ScheduleStatus::Following)
    heater.following_schedule?.should be_true
    SpecBroker.report(socket, {"device_name" => "heater", "serial_number" => "heater-1", "@SCHEDULESTATUS" => "Vendor status"})
    wait_for_update(updates)
    heater.schedule_status.should eq(EcoNet::ScheduleStatus::Unknown)
    heater.schedule_status_text.should eq("Vendor status")

    client.unsubscribe
    socket.read_bytes(MQTT::V3::Header).id.should eq(MQTT::RequestType::Disconnect)
  ensure
    client.try &.unsubscribe
    socket.try &.close
    broker.try &.close
    cloud.try &.close
  end

  it "restores the account subscriptions after the broker disconnects" do
    cloud = SpecCloud.new
    broker = SpecBroker.new
    client = cloud.login(broker)
    heater = client.get_equipment.first.as(EcoNet::WaterHeater)
    client.subscribe
    original, connect, _ = broker.connect
    original.close

    restored, reconnect, subscription = broker.connect
    reconnect.client_id.should eq(connect.client_id)
    reconnect.keep_alive_seconds.should eq(connect.keep_alive_seconds)
    subscription.topic_hash.keys.sort!.should eq([SpecBroker::DESIRED, SpecBroker::REPORTED])

    updates = Channel(Nil).new(1)
    heater.set_update_callback { updates.send(nil) }
    SpecBroker.report(restored, {"device_name" => "heater", "serial_number" => "heater-1", "@SETPOINT" => 137})
    wait_for_update(updates)
    heater.set_point.should eq(137)
    client.subscribed?.should be_true
  ensure
    client.try &.unsubscribe
    original.try &.close
    restored.try &.close
    broker.try &.close
    cloud.try &.close
  end
end
