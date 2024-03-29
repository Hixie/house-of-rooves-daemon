import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'house_sensors.dart';
import 'database/adaptors.dart';

// TODO(ianh): on startup, don't reset back to normal unless it's in a temporary heat or cool override mode
// TODO(ianh): heating/cooling override turn off fan when fan override mode is on and doors are open, because remy just has one "override" mode
// TODO(ianh): predicted temperature should affect targets (e.g. if it's going to be hot out in the next few hours, don't heat)
// TODO(ianh): need a way to turn to auto-unoccupied mode when we're absent

const double overrideDeltaUp = 3.00; // Celsius degrees for override modes (heating) // in winter, 2.00 was not enough to make ian happy at night downstairs
const double overrideDeltaDown = 0.75; // Celsius degrees for override modes (cooling)
const double quietDelta = 1.00; // Celsius degrees for quiet mode. 0.75 let it get warm but AC was still more annoying.
const double marginDelta = 0.45; // Celsius degrees for how far to overshoot when heating or cooling (at 0.5, ian kept looking at the logs as it shut down)
const double reservoirStartDelta = 2.0; // Celsius degrees for when to consider reservoir (3.0 led to overly hot upstairs; 2.5 led to overly cold downstairs)
const double reservoirEndDelta = 1.5; // Celsius degrees for when to consider reservoir

enum ThermostatOverride { heating, cooling, fan, quiet, alwaysHeat, alwaysCool, alwaysFan, alwaysOff }

const Duration lockoutDuration = const Duration(hours: 3, minutes: 15); // 2h15m seemed too short
enum ThermostatLockoutOperation { heating, cooling }

const Duration temperatureUpdatePeriod = const Duration(minutes: 10);
const Duration temperatureLifetime = const Duration(minutes: 15); // after 15 minutes we assume the data is obsolete

const Duration doorTimeout = const Duration(seconds: 20); // if door is open less than this time, we ignore it

const bool verbose = false;

final List<ThermostatRegime> schedule = <ThermostatRegime>[
  new ThermostatRegime(
    'night time',
    new DayTime(23, 30), new DayTime(00, 30),
    new TargetTemperature(20.0), new TargetTemperature(24.25), // 23.5 is unnecessarily cold, 23.75 was making ian tense from cold in the summer
    TemperatureSource.upstairs,
  ),
  new ThermostatRegime(
    'dead of night',
    new DayTime(00, 30), new DayTime(05, 30),
    new TargetTemperature(20.0), new TargetTemperature(25.0),
    TemperatureSource.upstairs,
  ),
  new ThermostatRegime(
    'early morning',
    new DayTime(05, 30), new DayTime(06, 30),
    new TargetTemperature(22.0), new TargetTemperature(26.0),
    TemperatureSource.upstairs,
  ),
  new ThermostatRegime(
    'morning',
    new DayTime(06, 30), new DayTime(09, 30),
    new TargetTemperature(22.0), // low was 23.5 but that caused heating in summer, as did 22.5; 22.0 did not, 22.25 sometimes seemed to...
    new TargetTemperature(26.0),
    TemperatureSource.upstairs,
  ),
  new ThermostatRegime(
    'day time',
    new DayTime(09, 30), new DayTime(21, 30),
    new TargetTemperature(22.40), // low: ian says 22 too cold, 22.5 too hot, 22.25 borderline too hot when it reaches 22.75, 22.15 too cold when it's cold outside...
    new TargetTemperature(24.25), // high: carey and elaine like 24.0; ian thinks that's way too cold but 25.0 is fine; except sometimes ian thinks 24.3 is too hot...
    TemperatureSource.downstairs,
  ),
  new ThermostatRegime(
    'evening',
    new DayTime(21, 30), new DayTime(22, 30),
    new TargetTemperature(22.0), new TargetTemperature(25.5), // during the summer the upstairs gets way hotten than this, but we don't want to freeze downstairs while cooling it
    TemperatureSource.upstairs,
  ),
  new ThermostatRegime(
    'late evening',
    new DayTime(22, 30), new DayTime(23, 30),
    new TargetTemperature(21.0), new TargetTemperature(24.5), // ...so we slowly ramp down over the evening
    TemperatureSource.upstairs,
  ),
];

abstract class _ThermostatModelState {
  const _ThermostatModelState();

  void configureThermostat(Thermostat thermostat);

  String get description;

  String get remyMode;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  bool operator ==(dynamic other) {
    return other.runtimeType == runtimeType;
  }

  @override
  String toString() => description;
}

class _RackOverheat extends _ThermostatModelState {
  const _RackOverheat();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.cool();
  }

  @override
  String get description => 'emergency cooling; rack overheat detected';

  @override
  String get remyMode => 'RackCool';
}

class _MaintenanceModeHeat extends _ThermostatModelState {
  const _MaintenanceModeHeat();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.heat();
  }

  @override
  String get description => 'maintenance mode forced heating';

  @override
  String get remyMode => 'Maintenance';
}

class _MaintenanceModeCool extends _ThermostatModelState {
  const _MaintenanceModeCool();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.cool();
  }

  @override
  String get description => 'maintenance mode forced cooling';

  @override
  String get remyMode => 'Maintenance';
}

class _MaintenanceModeFan extends _ThermostatModelState {
  const _MaintenanceModeFan();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.fan();
  }

  @override
  String get description => 'maintenance mode forced faning';

  @override
  String get remyMode => 'Maintenance';
}

class _MaintenanceModeOff extends _ThermostatModelState {
  const _MaintenanceModeOff();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.off();
  }

  @override
  String get description => 'maintenance mode forced off';

  @override
  String get remyMode => 'Maintenance';
}

class _DoorsOpen extends _ThermostatModelState {
  const _DoorsOpen();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.off();
  }

  @override
  String get description => 'disabling heating and cooling; external door(s) open';

  @override
  String get remyMode => 'DoorsOff';
}

class _HeatingDisabledDueToFumes extends _ThermostatModelState {
  const _HeatingDisabledDueToFumes();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: true);
    thermostat.off();
  }

  @override
  String get description => 'disabling heating; flammable fumes in garage';

  @override
  String get remyMode => 'FumesOff';
}

class _Heating extends _ThermostatModelState {
  const _Heating(this.target);

  final Temperature target;

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: false, green: true);
    thermostat.heat();
  }

  @override
  String get description => 'heating to $target...';

  @override
  int get hashCode => hashValues(runtimeType, target);

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType)
      return false;
    _Heating typedOther = other;
    return typedOther.target == target;
  }

  @override
  String get remyMode => 'Heat';
}

class _Cooling extends _ThermostatModelState {
  const _Cooling(this.target);

  final Temperature target;

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: false, green: true);
    thermostat.cool();
  }

  @override
  String get description => 'cooling to $target...';

  @override
  int get hashCode => hashValues(runtimeType, target);

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType)
      return false;
    _Cooling typedOther = other;
    return typedOther.target == target;
  }

  @override
  String get remyMode => 'Cool';
}

class _ForceHeating extends _ThermostatModelState {
  const _ForceHeating();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.heat();
  }

  @override
  String get description => 'heating due to override with no regime...';

  @override
  String get remyMode => 'Heat';
}

class _ForceCooling extends _ThermostatModelState {
  const _ForceCooling();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.cool();
  }

  @override
  String get description => 'cooling due to override with no regime...';

  @override
  String get remyMode => 'Cool';
}

abstract class _Fan extends _ThermostatModelState {
  const _Fan();

  bool get manualOverride;
  bool get rareSituation;

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: rareSituation, yellow: true, green: !manualOverride);
    thermostat.fan();
  }
}

class _ForceFan extends _Fan {
  const _ForceFan();

  @override
  String get description => 'circulating air due to override from Remy...';

  @override
  String get remyMode => 'Fan';

  @override
  bool get manualOverride => true;

  @override
  bool get rareSituation => false;
}

class _CleaningFan extends _Fan {
  const _CleaningFan();

  @override
  String get description => 'circulating air due to high indoor particulate matter levels...';

  @override
  String get remyMode => 'PM25Fan';

  @override
  bool get manualOverride => false;

  @override
  bool get rareSituation => true;
}

class _ReservoirFan extends _Fan {
  const _ReservoirFan({ @required this.reservoirWarmer });

  final bool reservoirWarmer;

  @override
  String get description => 'circulating air due to favourable temperature imbalance (${ reservoirWarmer ? "reservoir warmer" : "reservoir colder"})...';

  @override
  String get remyMode => 'Fan';

  @override
  bool get manualOverride => false;

  @override
  bool get rareSituation => false;

  @override
  int get hashCode => reservoirWarmer.hashCode;

  @override
  bool operator ==(dynamic other) {
    if (other.runtimeType != runtimeType)
      return false;
    _ReservoirFan typedOther = other;
    return typedOther.reservoirWarmer == reservoirWarmer;
  }
}

class _Idle extends _ThermostatModelState {
  const _Idle();

  @override
  String get description => 'idle';

  @override
  String get remyMode => 'Idle';

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: false, green: false);
    thermostat.auto(occupied: false);
  }
}

class _ForceIdle extends _ThermostatModelState {
  const _ForceIdle();

  @override
  String get description => 'idle due to override with no regime';

  @override
  String get remyMode => 'Idle';

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.auto(occupied: false);
  }
}

class _BlindIdle extends _ThermostatModelState {
  const _BlindIdle();

  @override
  String get description => 'idle due to insufficient data';

  @override
  String get remyMode => 'Idle';

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.auto(occupied: false);
  }
}

enum TemperatureSource { upstairs, downstairs }

class DayTime {
  const DayTime(this.hour, this.minute);
  DayTime.fromDateTime(DateTime dateTime) : hour = dateTime.hour, minute = dateTime.minute;
  final int hour;
  final int minute;

  int get asMinutesSinceMidnight => hour * 60 + minute;

  bool isAfter(DayTime other) => asMinutesSinceMidnight > other.asMinutesSinceMidnight;
  bool isBefore(DayTime other) => asMinutesSinceMidnight < other.asMinutesSinceMidnight;
  bool isAtOrAfter(DayTime other) => asMinutesSinceMidnight >= other.asMinutesSinceMidnight;
  bool isAtOrBefore(DayTime other) => asMinutesSinceMidnight <= other.asMinutesSinceMidnight;

  @override
  String toString() => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

class ThermostatRegime {
  ThermostatRegime(this.description, this.start, this.end, this.minimum, this.maximum, this.source) {
    assert(minimum < maximum);
  }
  final DayTime start;
  final DayTime end;
  final Temperature minimum;
  final Temperature maximum;
  final TemperatureSource source;
  final String description;

  bool isApplicable(DayTime now) {
    if (start.isBefore(end))
      return _compare(start, end, now);
    return !_compare(end, start, now);
  }

  static bool _compare(DayTime start, DayTime end, DayTime now) {
    assert(start.isBefore(end));
    return now.isAtOrAfter(start) && now.isBefore(end);
  }

  @override
  String toString() => '$description ($start to $end; temperature range $minimum .. $maximum)';
}

class _ThermostatModelStateDescription {
  _ThermostatModelStateDescription(this.state, this.why);

  final _ThermostatModelState state;

  final String why;
}

class ThermostatModel extends Model {
  ThermostatModel(this.thermostat, this.remy, this.houseSensors, {
    this.indoorAirQuality,
    this.upstairsTemperature,
    this.downstairsTemperature,
    this.rackTemperature,
    LogCallback onLog,
  }) : super(onLog: onLog) {
    _subscriptions.add(thermostat.status.listen(_handleThermostatStatus));
    _subscriptions.add(remy.getStreamForNotification('garage-has-fumes').listen(_handleRemyGarageHasFumesNotification));
    _subscriptions.add(remy.getStreamForNotificationWithArgument('thermostat-override').listen(_handleRemyOverride));
    _subscriptions.add(houseSensors.frontDoor.listen(_handleFrontDoor));
    _subscriptions.add(houseSensors.backDoor.listen(_handleBackDoor));
    _subscriptions.add(indoorAirQuality.listen(_handleIndoorAirQuality));
    _subscriptions.add(upstairsTemperature.listen(_handleUpstairsTemperature));
    _subscriptions.add(downstairsTemperature.listen(_handleDownstairsTemperature));
    _subscriptions.add(rackTemperature.listen(_handleRackTemperature));
    _reportTimer = new Timer(const Duration(seconds: 1), () {
      _report();
      _reportTimer = new Timer(const Duration(seconds: 5), () {
        _report();
        _reportTimer = new Timer.periodic(temperatureUpdatePeriod, _report);
      });
    });
    log('model initialised');
    _disableOverride();
    _processData();
  }

  final Thermostat thermostat;
  final RemyMultiplexer remy;
  final HouseSensorsModel houseSensors;
  final Stream<MeasurementPacket> indoorAirQuality;
  final Stream<Temperature> downstairsTemperature;
  final Stream<Temperature> upstairsTemperature;
  final Stream<Temperature> rackTemperature;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  Temperature _currentRackTemperature;
  Temperature _currentDownstairsTemperature;
  Temperature _currentUpstairsTemperature;
  Measurement _currentIndoorsPM2_5;
  ThermostatOverride _currentThermostatOverride;

  bool _currentFrontDoorState;
  bool _currentBackDoorState;
  bool _doorsOpen = false;
  bool _garageHasFumes = false;

  Temperature _temperatureAtOverrideTime;
  ThermostatRegime _regimeAtOverrideTime;
  ThermostatRegime _currentRegime;
  _ThermostatModelState _currentState;
  ThermostatLockoutOperation _lockout;
  DateTime _lockoutStart;

  Timer _reportTimer;

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
    _reportTimer.cancel();
  }

  static bool _exceeds(Temperature temperature, Temperature target) {
    if (temperature == null)
      return false;
    return temperature > target;
  }

  static bool _isTrue(bool state) {
    if (state == null)
      return false;
    return state;
  }

  static String _describeDoor(bool state, String name) {
    StringBuffer buffer = new StringBuffer('$name door is ');
    if (state == null) {
      buffer.write('in an unknown state');
    } else if (state) {
      buffer.write('open');
    } else {
      buffer.write('closed');
    }
    return buffer.toString();
  }

  bool _lockedOut(ThermostatLockoutOperation wantedMode, { DateTime now }) {
    now ??= DateTime.now();
    if (_lockoutStart == null)
      return false;
    return _lockoutStart != null
        && _lockout != null
        && _lockout != wantedMode
        && now.difference(_lockoutStart) < lockoutDuration;
  }

  _ThermostatModelStateDescription computeMode() {
    // First the overrides
    switch (_currentThermostatOverride) {
      case ThermostatOverride.alwaysHeat:
        return new _ThermostatModelStateDescription(const _MaintenanceModeHeat(), 'maintenance mode override to heat');
      case ThermostatOverride.alwaysCool:
        return new _ThermostatModelStateDescription(const _MaintenanceModeCool(), 'maintenance mode override to cool');
      case ThermostatOverride.alwaysFan:
        return new _ThermostatModelStateDescription(const _MaintenanceModeFan(), 'maintenance mode override to fan');
      case ThermostatOverride.alwaysOff:
        return new _ThermostatModelStateDescription(const _MaintenanceModeOff(), 'maintenance mode override to off');
      default:
        if (_exceeds(_currentRackTemperature, new TargetTemperature(40.0)))
          return new _ThermostatModelStateDescription(const _RackOverheat(), 'rack is at $_currentRackTemperature');
        if (_doorsOpen) {
          final String doorState = '${_describeDoor(_currentFrontDoorState, 'front')}, ${_describeDoor(_currentBackDoorState, 'back')}';
          if (_currentThermostatOverride == ThermostatOverride.fan)
            return new _ThermostatModelStateDescription(const _ForceFan(), '$doorState, but fan override specified');
          return new _ThermostatModelStateDescription(const _DoorsOpen(), doorState);
        }
        break;
    }
    // None of the overrides apply, so now let's consider the current regime.
    final DayTime now = new DayTime.fromDateTime(new DateTime.now());
    final ThermostatRegime regime = schedule.firstWhere(
      (ThermostatRegime candidate) => candidate.isApplicable(now),
      orElse: () => null,
    );
    if (regime != _currentRegime) {
      log('new thermal regime: ${regime ?? "<none>"}');
      _currentRegime = regime;
    }
    Temperature minimum, maximum, currentTemperature, reservoirTemperature;
    bool ensureFan = false;
    String regimeAdjective = '';
    if (regime != null) {
      regimeAdjective = '${regime.description} ';
      minimum = regime.minimum;
      maximum = regime.maximum;
      switch (regime.source) {
        case TemperatureSource.upstairs:
          currentTemperature = _currentUpstairsTemperature;
          reservoirTemperature = _currentDownstairsTemperature;
          if (verbose)
            log('using upstairs temperature (currently $currentTemperature); reservoir downstairs ($reservoirTemperature)');
          break;
        case TemperatureSource.downstairs:
          currentTemperature = _currentDownstairsTemperature;
          reservoirTemperature = _currentUpstairsTemperature;
          if (verbose)
            log('using downstairs temperature (currently $currentTemperature); reservoir upstairs ($reservoirTemperature)');
          break;
      }
    }
    if (_currentThermostatOverride != null) {
      if (_temperatureAtOverrideTime == null)
        _temperatureAtOverrideTime = currentTemperature;
      if (_regimeAtOverrideTime == null)
        _regimeAtOverrideTime = regime;
      switch (_currentThermostatOverride) {
        case ThermostatOverride.heating:
          if ((currentTemperature != null && _temperatureAtOverrideTime != null &&
               currentTemperature > _temperatureAtOverrideTime.correct(overrideDeltaUp))) {
            log('achieved requested temperature increase (now at $currentTemperature, above ${_temperatureAtOverrideTime.correct(overrideDeltaUp)}); canceling override.');
            _disableOverride();
          } else if (regime != _regimeAtOverrideTime) {
            log('entered new thermostat regime since override request; canceling override.');
            _disableOverride();
          } else if (minimum == null) {
            if (_garageHasFumes)
              return new _ThermostatModelStateDescription(new _HeatingDisabledDueToFumes(), 'no temperature available; heating override selected');
            return new _ThermostatModelStateDescription(new _ForceHeating(), 'no temperature available; heating override selected');
          } else {
            if (_temperatureAtOverrideTime != null) {
              minimum = _temperatureAtOverrideTime.correct(overrideDeltaUp);
              if (maximum < minimum)
                maximum = minimum.correct(overrideDeltaUp);
              regimeAdjective = 'override ';
            } else {
              minimum = minimum.correct(overrideDeltaUp);
              regimeAdjective = 'overridden $regimeAdjective';
            }
          }
          break;
        case ThermostatOverride.cooling:
          if ((currentTemperature != null && _temperatureAtOverrideTime != null &&
               currentTemperature < _temperatureAtOverrideTime.correct(-overrideDeltaDown))) {
            log('achieved requested temperature decrease (now at $currentTemperature, below ${_temperatureAtOverrideTime.correct(-overrideDeltaDown)}); canceling override.');
            _disableOverride();
          } else if (regime != _regimeAtOverrideTime) {
            log('entered new thermostat regime since override request; canceling override.');
            _disableOverride();
          } else if (maximum == null) {
            return new _ThermostatModelStateDescription(new _ForceCooling(), 'no temperature available; cooling override selected');
          } else {
            if (_temperatureAtOverrideTime != null) {
              maximum = _temperatureAtOverrideTime.correct(-overrideDeltaDown);
              if (minimum > maximum)
                minimum = maximum.correct(-overrideDeltaDown);
              regimeAdjective = 'override ';
            } else {
              maximum = maximum.correct(-overrideDeltaDown);
              regimeAdjective = 'overridden $regimeAdjective';
            }
          }
          break;
        case ThermostatOverride.fan:
          ensureFan = true;
          break;
        case ThermostatOverride.quiet:
          if (minimum == null || maximum == null)
            return new _ThermostatModelStateDescription(new _ForceIdle(), 'no regime selected; quiet override active');
          minimum = minimum.correct(-quietDelta);
          maximum = maximum.correct(quietDelta);
          regimeAdjective = 'quiet $regimeAdjective';
          break;
        default:
          assert(false);
      }
    }
    if (_lockedOut(ThermostatLockoutOperation.heating)) {
      minimum = minimum == null ? new TargetTemperature(18.0) : minimum.correct(-10.0);
      regimeAdjective = '$regimeAdjective(heating locked out) ';
    }
    if (_lockedOut(ThermostatLockoutOperation.cooling)) {
      maximum = maximum == null ? new TargetTemperature(32.0) : maximum.correct(10.0);
      regimeAdjective = '$regimeAdjective(cooling locked out) ';
    }
    if (verbose)
      log('minimum temperature: $minimum; maximum temperature: $maximum; current temperature: $currentTemperature; reservoirTemperature: $reservoirTemperature; lockout: $_lockout');
    if (minimum != null && maximum != null && currentTemperature != null && reservoirTemperature != null) {
      assert(minimum < maximum, 'regime out of range: minimum temperature: $minimum; maximum temperature: $maximum; current temperature: $currentTemperature; lockout: $_lockout');
      if (currentTemperature < minimum) {
        if (reservoirTemperature > minimum.correct(reservoirStartDelta) && _currentState is! _Heating)
          return new _ThermostatModelStateDescription(_ReservoirFan(reservoirWarmer: true), 'current temperature $currentTemperature below ${regimeAdjective}minimum $minimum, but reservoir temperature ($reservoirTemperature) is above minimum');
        if (_garageHasFumes)
          return new _ThermostatModelStateDescription(new _HeatingDisabledDueToFumes(), 'current temperature $currentTemperature below ${regimeAdjective}minimum $minimum (reservoir temperature $reservoirTemperature is not sufficiently above minimum)');
        return new _ThermostatModelStateDescription(new _Heating(minimum.correct(marginDelta)), 'current temperature $currentTemperature below ${regimeAdjective}minimum $minimum (reservoir temperature $reservoirTemperature is not sufficiently above minimum)');
      } else if (currentTemperature > maximum) {
        if (reservoirTemperature < maximum.correct(-reservoirStartDelta) && _currentState is! _Cooling)
          return new _ThermostatModelStateDescription(_ReservoirFan(reservoirWarmer: false), 'current temperature $currentTemperature above ${regimeAdjective}maximum $maximum, but reservoir temperature ($reservoirTemperature) is below maximum');
        return new _ThermostatModelStateDescription(new _Cooling(maximum.correct(-marginDelta)), 'current temperature $currentTemperature above ${regimeAdjective}maximum $maximum (reservoir temperature $reservoirTemperature is not sufficiently below maximum)');
      } else if (_currentState is _Heating || _currentState is _ForceHeating) {
        if (currentTemperature < minimum.correct(marginDelta)) {
          if (_garageHasFumes)
            return new _ThermostatModelStateDescription(new _HeatingDisabledDueToFumes(), 'current temperature $currentTemperature; continuing heating until above ${regimeAdjective}$minimum by $marginDelta');
          return new _ThermostatModelStateDescription(new _Heating(minimum.correct(marginDelta)), 'current temperature $currentTemperature; continuing heating until above ${regimeAdjective}$minimum by $marginDelta');
        }
      } else if (_currentState is _Cooling || _currentState is _ForceCooling) {
        if (currentTemperature > maximum.correct(-marginDelta))
          return new _ThermostatModelStateDescription(new _Cooling(maximum.correct(-marginDelta)), 'current temperature $currentTemperature; continuing cooling until below ${regimeAdjective}$maximum by $marginDelta');
      } else if (_currentState is _ReservoirFan) {
        if ((_currentState as _ReservoirFan).reservoirWarmer) {
          if ((currentTemperature.correct(reservoirEndDelta) < reservoirTemperature) && (currentTemperature < maximum)) {
            return new _ThermostatModelStateDescription(_ReservoirFan(reservoirWarmer: true), 'continuing to warm using the fan since current temperature $currentTemperature is less than the maximum ($maximum) and much less than the reservoir ($reservoirTemperature)');
          }
        } else {
          if ((currentTemperature.correct(-reservoirEndDelta) > reservoirTemperature) && (currentTemperature > minimum)) {
            return new _ThermostatModelStateDescription(_ReservoirFan(reservoirWarmer: false), 'continuing to cool using the fan since current temperature $currentTemperature is more than the minimum ($minimum) and much more than the reservoir ($reservoirTemperature)');
          }
        }
      }
    }
    if (ensureFan)
      return new _ThermostatModelStateDescription(const _ForceFan(), '$currentTemperature within ${regimeAdjective}thermal regime, but fan override specified');
    if (_currentIndoorsPM2_5 != null && _currentIndoorsPM2_5.value > 10.0)
      return new _ThermostatModelStateDescription(const _CleaningFan(), '$currentTemperature within ${regimeAdjective}thermal regime, but indoor particulate matter is ${_currentIndoorsPM2_5}');
    if (currentTemperature == null)
      return new _ThermostatModelStateDescription(const _BlindIdle(), 'current temperature not yet available');
    if (minimum != null && maximum != null)
      return new _ThermostatModelStateDescription(const _Idle(), '$currentTemperature within ${regimeAdjective}thermal regime $minimum .. $maximum');
    return new _ThermostatModelStateDescription(const _BlindIdle(), 'no minimum and maximum available in ${regimeAdjective}thermal regime to which to compare current temperature $currentTemperature');
  }

  void _processData() {
    _ThermostatModelStateDescription targetState = computeMode();
    if (targetState.state != _currentState) {
      log('new selected mode: ${targetState.state.description} (${targetState.why})');
      targetState.state.configureThermostat(thermostat);
      remy.pushButtonById('thermostatTargetMode${targetState.state.remyMode}');
      _currentState = targetState.state;
      _report();
    } else {
      if (verbose)
        log('continuing with existing mode: ${_currentState}');
    }
  }

  @override
  set privateMode(bool value) {
    super.privateMode = value;
    if (privateMode) {
      thermostat.auto(occupied: true);
    } else {
      _processData();
    }
  }

  bool _needLockout = false;

  void _handleThermostatStatus(ThermostatStatus value) {
    if (value == null)
      return;
    if (_needLockout) {
      _lockoutStart = new DateTime.now();
      _needLockout = false;
    }
    switch (value) {
      case ThermostatStatus.heating:
        log('actual current status: heating');
        remy.pushButtonById('thermostatModeHeat');
        _lockout = ThermostatLockoutOperation.heating;
        _lockoutStart = new DateTime.now();
        _needLockout = true;
        break;
      case ThermostatStatus.cooling:
        log('actual current status: cooling');
        remy.pushButtonById('thermostatModeCool');
        _lockout = ThermostatLockoutOperation.cooling;
        _lockoutStart = new DateTime.now();
        _needLockout = true;
        break;
      case ThermostatStatus.fan:
        log('actual current status: fan active');
        remy.pushButtonById('thermostatModeFan');
        break;
      case ThermostatStatus.idle:
        log('actual current status: idle');
        remy.pushButtonById('thermostatModeIdle');
        break;
    }
  }

  void _handleRemyGarageHasFumesNotification(bool value) {
    _garageHasFumes = value;
    _processData();
  }

  void _handleRemyOverride(String override) {
    log('received remy thermostat override instruction: $override');
    switch (override) {
      case 'heat':
        _currentThermostatOverride = ThermostatOverride.heating;
        break;
      case 'cool':
        _currentThermostatOverride = ThermostatOverride.cooling;
        break;
      case 'fan':
        _currentThermostatOverride = ThermostatOverride.fan;
        break;
      case 'quiet':
        _currentThermostatOverride = ThermostatOverride.quiet;
        break;
      case 'alwaysHeat':
        _currentThermostatOverride = ThermostatOverride.alwaysHeat;
        break;
      case 'alwaysCool':
        _currentThermostatOverride = ThermostatOverride.alwaysCool;
        break;
      case 'alwaysFan':
        _currentThermostatOverride = ThermostatOverride.alwaysFan;
        break;
      case 'alwaysOff':
        _currentThermostatOverride = ThermostatOverride.alwaysOff;
        break;
      case 'normal':
        _currentThermostatOverride = null;
        break;
      default:
        log('unknown remy override for thermostat: $override');
    }
    _temperatureAtOverrideTime = null;
    _regimeAtOverrideTime = null;
    _processData();
  }

  void _disableOverride() {
    remy.pushButtonById('thermostatJustFine');
    _currentThermostatOverride = null;
    _temperatureAtOverrideTime = null;
    _regimeAtOverrideTime = null;
  }

  void _handleIndoorAirQuality(MeasurementPacket value) {
    if (value == null)
      return;
    _currentIndoorsPM2_5 = value.pm2_5;
    _processData();
  }

  void _handleUpstairsTemperature(Temperature value) {
    if (value == null)
      return;
    _currentUpstairsTemperature = value;
    _processData();
  }

  void _handleDownstairsTemperature(Temperature value) {
    if (value == null)
      return;
    _currentDownstairsTemperature = value;
    _processData();
  }

  void _handleRackTemperature(Temperature value) {
    if (value == null)
      return;
    _currentRackTemperature = value;
    _processData();
  }

  void _handleFrontDoor(bool value) {
    if (value == null)
      return;
    _currentFrontDoorState = value;
    _updateDoors();
  }

  void _handleBackDoor(bool value) {
    if (value == null)
      return;
    _currentBackDoorState = value;
    _updateDoors();
  }

  Timer _doorTimer;

  void _updateDoors() {
    if (_isTrue(_currentFrontDoorState) || _isTrue(_currentBackDoorState)) {
      if (!_doorsOpen && _doorTimer == null) {
        _doorTimer = Timer(doorTimeout, () {
          _doorsOpen = true;
          _doorTimer = null;
          _processData();
        });
      }
    } else {
      _doorTimer?.cancel();
      _doorTimer = null;
      if (_doorsOpen) {
        _doorsOpen = false;
        _processData();
      }
    }
  }

  void _report([ Timer timer ]) {
    String additional = '';
    if (_currentThermostatOverride != null)
      additional += '; override: ${_currentThermostatOverride}';
    final DateTime now = DateTime.now();
    if (_lockedOut(null, now: now)) {
      final String remaining = prettyDuration(lockoutDuration - now.difference(_lockoutStart));
      additional += '; lockout: $_lockout ($remaining remaining)';
    }
    log('upstairs=${_currentUpstairsTemperature}; downstairs=${_currentDownstairsTemperature}; rack=${_currentRackTemperature}; indoor PM₂.₅: ${_currentIndoorsPM2_5}; regime: $_currentRegime; state: $_currentState$additional');
  }
}

class ThermostatDataAdaptor extends StreamDataAdaptor<ThermostatReport> {
  ThermostatDataAdaptor({int tableId, Stream<ThermostatReport> stream}) : super(tableId, stream);

  @override
  Uint8List adapt(ThermostatReport next) => next?.encode() ?? Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF]);
}
