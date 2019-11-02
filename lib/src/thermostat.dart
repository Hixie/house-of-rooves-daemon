import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'house_sensors.dart';

// TODO(ianh): maybe outside temperature should affect targets?

const double overrideDelta = 2.0; // Celsius degrees for override modes
const double marginDelta = 0.9; // Celsius degrees for how far to overshoot when heating or cooling

const bool verbose = true;

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
}

class _RackOverheat extends _ThermostatModelState {
  const _RackOverheat();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: true, yellow: false, green: false);
    thermostat.cool();
  }

  @override
  String get description => 'Emergency cooling; rack overheat detected.';

  @override
  String get remyMode => 'RackCool';
}

class _DoorsOpen extends _ThermostatModelState {
  const _DoorsOpen();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.off();
  }

  @override
  String get description => 'Disabling heating and cooling; external door(s) open.';

  @override
  String get remyMode => 'DoorsOff';
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
  String get description => 'Heating to $target...';

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
  String get description => 'Cooling to $target...';

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
  String get description => 'Heating due to override with no regime...';

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
  String get description => 'Cooling due to override with no regime...';

  @override
  String get remyMode => 'Cool';
}

abstract class _Fan extends _ThermostatModelState {
  const _Fan();

  @override
  void configureThermostat(Thermostat thermostat) {
    thermostat.setLeds(red: false, yellow: true, green: false);
    thermostat.fan();
  }
}

class _ForceFan extends _Fan {
  const _ForceFan();

  @override
  String get description => 'Circulating air due to override...';

  @override
  String get remyMode => 'Fan';
}

class _CleaningFan extends _Fan {
  const _CleaningFan();

  @override
  String get description => 'Circulating air due to high indoor particulate matter levels...';

  @override
  String get remyMode => 'PM25Fan';
}

class _Idle extends _ThermostatModelState {
  const _Idle();

  @override
  String get description => 'Idle.';

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
  String get description => 'Idle due to override with no regime.';

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
  ThermostatRegime(this.start, this.end, this.minimum, this.maximum, this.source, this.description) {
    assert(minimum.correct(overrideDelta) < maximum);
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

enum ThermostatOverride { heating, cooling, fan, quiet }

class ThermostatModel extends Model {
  ThermostatModel(this.thermostat, this.remy, this.houseSensors, {
    this.outdoorAirQuality,
    this.indoorAirQuality,
    this.upstairsTemperature,
    this.downstairsTemperature,
    this.rackTemperature,
    LogCallback onLog,
  }) : super(onLog: onLog) {
    _subscriptions.add(thermostat.status.listen(_handleThermostatStatus));
    _subscriptions.add(thermostat.temperature.listen(_handleThermostatTemperature));
    _subscriptions.add(remy.getStreamForNotificationWithArgument('thermostat-override').listen(_handleRemyOverride));
    _subscriptions.add(houseSensors.frontDoor.listen(_handleFrontDoor));
    _subscriptions.add(houseSensors.backDoor.listen(_handleBackDoor));
    _subscriptions.add(indoorAirQuality.listen(_handleIndoorAirQuality));
    _subscriptions.add(outdoorAirQuality.listen(_handleOutdoorAirQuality));
    _subscriptions.add(upstairsTemperature.listen(_handleUpstairsTemperature));
    _subscriptions.add(downstairsTemperature.listen(_handleDownstairsTemperature));
    _subscriptions.add(rackTemperature.listen(_handleRackTemperature));
    _currentRackTemperature = new CurrentValue<Temperature>();
    _currentIndoorAirQualityTemperature = new CurrentValue<Temperature>();
    _currentThermostatTemperature = new CurrentValue<Temperature>(fallback: _currentIndoorAirQualityTemperature);
    _currentDownstairsTemperature = new CurrentValue<Temperature>(fallback: _currentThermostatTemperature);
    _currentUpstairsTemperature = new CurrentValue<Temperature>(fallback: _currentDownstairsTemperature);
    _currentIndoorsPM2_5 = new CurrentValue<Measurement>();
    _currentFrontDoorState = new CurrentValue<bool>();
    _currentBackDoorState = new CurrentValue<bool>();
    _currentThermostatOverride = new CurrentValue<ThermostatOverride>();
    _disableOverride();
    _processData();
    log('model initialised');
  }

  final Thermostat thermostat;
  final RemyMultiplexer remy;
  final HouseSensorsModel houseSensors;
  final Stream<MeasurementPacket> outdoorAirQuality;
  final Stream<MeasurementPacket> indoorAirQuality;
  final Stream<Temperature> downstairsTemperature;
  final Stream<Temperature> upstairsTemperature;
  final Stream<Temperature> rackTemperature;

  static List<ThermostatRegime> schedule = <ThermostatRegime>[
    new ThermostatRegime(
      new DayTime(21, 30), new DayTime(06, 30),
      new TargetTemperature(21.0), new TargetTemperature(24.0),
      TemperatureSource.upstairs,
      'night time',
    ),
    new ThermostatRegime(
      new DayTime(06, 30), new DayTime(09, 30),
      new TargetTemperature(25.0), new TargetTemperature(28.0),
      TemperatureSource.upstairs,
      'morning',
    ),
    new ThermostatRegime(
      new DayTime(09, 30), new DayTime(21, 30),
      new TargetTemperature(23.0), new TargetTemperature(26.0),
      TemperatureSource.downstairs,
      'day time'
    ),
  ];

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  CurrentValue<Temperature> _currentRackTemperature;
  CurrentValue<Temperature> _currentIndoorAirQualityTemperature;
  CurrentValue<Temperature> _currentThermostatTemperature;
  CurrentValue<Temperature> _currentDownstairsTemperature;
  CurrentValue<Temperature> _currentUpstairsTemperature;
  CurrentValue<Measurement> _currentIndoorsPM2_5;
  CurrentValue<bool> _currentFrontDoorState;
  CurrentValue<bool> _currentBackDoorState;
  CurrentValue<ThermostatOverride> _currentThermostatOverride;

  Temperature _temperatureAtOverrideTime;
  ThermostatRegime _regimeAtOverrideTime;
  ThermostatRegime _currentRegime;
  _ThermostatModelState _currentState;

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
    _currentRackTemperature.dispose();
    _currentIndoorAirQualityTemperature.dispose();
    _currentThermostatTemperature.dispose();
    _currentDownstairsTemperature.dispose();
    _currentUpstairsTemperature.dispose();
    _currentFrontDoorState.dispose();
    _currentBackDoorState.dispose();
    _currentThermostatOverride.dispose();
  }

  static bool _exceeds(CurrentValue<Temperature> temperature, Temperature target) {
    if (temperature.value == null)
      return false;
    return temperature.value > target;
  }

  static bool _isTrue(CurrentValue<bool> state) {
    if (state.value == null)
      return false;
    return state.value;
  }

  _ThermostatModelState computeMode() {
    if (_exceeds(_currentRackTemperature, new TargetTemperature(40.0)))
      return const _RackOverheat();
    if (_isTrue(_currentFrontDoorState) || _isTrue(_currentBackDoorState))
      return const _DoorsOpen();
    final DayTime now = new DayTime.fromDateTime(new DateTime.now());
    final ThermostatRegime regime = schedule.firstWhere(
      (ThermostatRegime candidate) => candidate.isApplicable(now),
      orElse: () => null,
    );
    if (regime != _currentRegime) {
      log('new thermal regime: ${regime ?? "<none>"}');
      _currentRegime = regime;
    }
    Temperature minimum, maximum, currentTemperature;
    bool ensureFan = false;
    if (regime != null) {
      minimum = regime.minimum;
      maximum = regime.maximum;
      switch (regime.source) {
        case TemperatureSource.upstairs:
          currentTemperature = _currentUpstairsTemperature.value;
          if (verbose)
            log('using upstairs temperature (currently $currentTemperature)');
          break;
        case TemperatureSource.downstairs:
          currentTemperature = _currentDownstairsTemperature.value;
            log('using downstairs temperature (currently $currentTemperature)');
          break;
      }
    }
    if (_currentThermostatOverride.value != null) {
      if (_temperatureAtOverrideTime == null)
        _temperatureAtOverrideTime = currentTemperature;
      if (_regimeAtOverrideTime == null)
        _regimeAtOverrideTime = regime;
      switch (_currentThermostatOverride.value) {
        case ThermostatOverride.heating:
          if ((currentTemperature != null && _temperatureAtOverrideTime != null &&
               currentTemperature > _temperatureAtOverrideTime.correct(overrideDelta))) {
            log('achieved requested temperature increase; canceling override.');
            _disableOverride();
          } else if (regime != _regimeAtOverrideTime) {
            log('entered new thermostat regime since override request; canceling override.');
            _disableOverride();
          } else if (minimum == null) {
            return new _ForceHeating();
          } else if (_temperatureAtOverrideTime != null) {
            minimum = _temperatureAtOverrideTime.correct(overrideDelta);
            if (maximum < minimum)
              maximum = minimum.correct(overrideDelta);
          } else {
            minimum = minimum.correct(overrideDelta);
          }
          break;
        case ThermostatOverride.cooling:
          if ((currentTemperature != null && _temperatureAtOverrideTime != null &&
               currentTemperature < _temperatureAtOverrideTime.correct(-overrideDelta))) {
            log('achieved requested temperature decrease; canceling override.');
            _disableOverride();
          } else if (regime != _regimeAtOverrideTime) {
            log('entered new thermostat regime since override request; canceling override.');
            _disableOverride();
          } else if (maximum == null) {
            return new _ForceCooling();
          } else if (_temperatureAtOverrideTime != null) {
            maximum = _temperatureAtOverrideTime.correct(-overrideDelta);
            if (minimum > maximum)
              minimum = maximum.correct(-overrideDelta);
          } else {
            maximum = maximum.correct(-overrideDelta);
          }
          break;
        case ThermostatOverride.fan:
          ensureFan = true;
          break;
        case ThermostatOverride.quiet:
          if (minimum == null || maximum == null)
            return new _ForceIdle();
          minimum = minimum.correct(-overrideDelta);
          maximum = maximum.correct(overrideDelta);
          break;
      }
    }
    if (verbose)
      log('minimum temperature: $minimum; maximum temperature: $maximum; current temperature: $currentTemperature');
    if (minimum != null && maximum != null && currentTemperature != null) {
      assert(minimum < maximum);
      if (currentTemperature < minimum) {
        return new _Heating(minimum);
      } else if (currentTemperature > maximum) {
        return new _Cooling(maximum);
      } else if (_currentState is _Heating || _currentState is _ForceHeating) {
        if (currentTemperature < minimum.correct(marginDelta))
          return new _Heating(minimum);
      } else if (_currentState is _Cooling || _currentState is _ForceCooling) {
        if (currentTemperature > maximum.correct(-marginDelta))
          return new _Cooling(maximum);
      }
    }
    if (ensureFan)
      return const _ForceFan();
    if (_currentIndoorsPM2_5.value != null && _currentIndoorsPM2_5.value.value > 10.0)
      return const _CleaningFan();
    return const _Idle();
  }

  void _processData() {
    _ThermostatModelState targetState = computeMode();
    if (targetState != _currentState) {
      targetState.configureThermostat(thermostat);
      log('new selected mode: ${targetState.description}');
      remy.pushButtonById('thermostatMode${targetState.remyMode}');
      _currentState = targetState;
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

  void _handleThermostatStatus(ThermostatStatus value) {
    if (value == null)
      return;
    switch (value) {
      case ThermostatStatus.heating:
        log('actual current status: heating');
        remy.pushButtonById('thermostatModeHeat');
        break;
      case ThermostatStatus.cooling:
        log('actual current status: cooling');
        remy.pushButtonById('thermostatModeCool');
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

  void _handleThermostatTemperature(Temperature value) {
    if (value == null)
      return;
    _currentThermostatTemperature.value = value.correct(-1.0);
    _processData();
  }

  void _handleRemyOverride(String override) {
    if (verbose)
      log('received remy thermostat override instruction: $override');
    switch (override) {
      case 'heat':
        _currentThermostatOverride.value = ThermostatOverride.heating;
        break;
      case 'cool':
        _currentThermostatOverride.value = ThermostatOverride.cooling;
        break;
      case 'fan':
        _currentThermostatOverride.value = ThermostatOverride.fan;
        break;
      case 'quiet':
        _currentThermostatOverride.value = ThermostatOverride.quiet;
        break;
      case 'normal':
        _currentThermostatOverride.value = null;
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
    _currentThermostatOverride.value = null;
    _temperatureAtOverrideTime = null;
    _regimeAtOverrideTime = null;
  }

  void _handleIndoorAirQuality(MeasurementPacket value) {
    if (value == null)
      return;
    _currentIndoorAirQualityTemperature.value = value.temperature.correct(-4.0);
    _currentIndoorsPM2_5.value = value.pm2_5;
    _processData();
  }

  void _handleOutdoorAirQuality(MeasurementPacket value) {
    if (value == null)
      return;
    // track outdoor pm2.5
    _processData();
  }

  void _handleUpstairsTemperature(Temperature value) {
    if (value == null)
      return;
    _currentUpstairsTemperature.value = value;
    _processData();
  }

  void _handleDownstairsTemperature(Temperature value) {
    if (value == null)
      return;
    _currentDownstairsTemperature.value = value;
    _processData();
  }

  void _handleRackTemperature(Temperature value) {
    if (value == null)
      return;
    _currentRackTemperature.value = value;
    _processData();
  }

  void _handleFrontDoor(bool value) {
    if (value == null)
      return;
    _currentFrontDoorState.value = value;
    _processData();
  }

  void _handleBackDoor(bool value) {
    if (value == null)
      return;
    _currentBackDoorState.value = value;
    _processData();
  }
}

class CurrentValue<T> {
  CurrentValue({ this.lifetime, this.fallback });

  final Duration lifetime;
  final CurrentValue<T> fallback;
  
  Timer _timer;

  T get value => _value ?? fallback?.value;
  T _value;
  set value(T newValue) {
    _value = newValue;
    _timer?.cancel();
    if (lifetime != null)
      _timer = new Timer(lifetime, () { _value = null; });
  }

  void dispose() {
    _timer?.cancel();
  }
}
