import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

// TODO(ianh): maybe outside temperature should affect targets?

class ThermostatModel extends Model {
  ThermostatModel(this.thermostat, this.airQuality, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(thermostat.temperature.listen(_handleThermostatTemperature));
    _subscriptions.add(thermostat.status.listen(_handleThermostatStatus));
    _subscriptions.add(airQuality.value.listen(_handleAirQuality));
    log('model initialised');
  }

  final AirNowAirQualityMonitor airQuality;
  final Thermostat thermostat;
  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  // handle private mode by going to auto-occupied mode
  // reprocess data when exiting private mode

  void _processData() {
    // turn cooling on if rack is above 39C, red
    // turn everything off if front door or back door is open, yellow
    // otherwise, green and continue:
    // select temperature based on time of day, room occupancy, etc
       // 
    // select target temperature range based on time of day, room occupancy
       // 
    // if tv is on bristol or roku, increase range by 2 degrees either way
    // if below minimum, or if already heating and below minimum+1, heat
    // if above maximum, or if already cooling and above maximum-1, cool
    // if internal air quality is bad, fan
    // off
  }

  void _handleAirQuality(MeasurementPacket value) {
    if (value == null)
      return;
    // track air quality...
  }

  void _handleThermostatTemperature(ThermostatTemperature value) {
    if (value == null)
      return;
    // track temperature...
  }

  void _handleThermostatStatus(ThermostatStatus value) {
    if (value == null)
      return;
    // track status...
    // tell remy
    // 
  }
}

// track remy. when a thermostat override is set, remember current temperature. reset when temperature moves in the right direction by 2 degrees.
// also, replace applicable target in current time region - store on disk??
// 
