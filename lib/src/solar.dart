import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class SolarModel extends Model {
  SolarModel(this._cloudbit, this.monitor, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _motionStream = new AlwaysOnWatchStream<bool>();
    _subscriptions.add(_cloudbit.values.listen(_motionSensor));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'family room solar display', slop: 255.0, reportingThreshold: 10.0)));
    _subscriptions.add(monitor.power.listen(_power));
    _subscriptions.add(motionStream.listen(_motionRemyProxy));
    log('model initialised');
  }

  final CloudBit _cloudbit;
  final SunPowerMonitor monitor;
  final RemyMultiplexer remy;

  static const Duration motionIdleDuration = const Duration(minutes: 15);
  static const Duration remyUpdatePeriod = const Duration(minutes: 60);

  WatchStream<bool> get motionStream => _motionStream;
  WatchStream<bool> _motionStream;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    _motionStoppedTimer?.cancel();
    _motionStream.close();
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  double _lastPower;

  void _power(double value) {
    if (value == null)
      return;
    double newValue = (value * 10.0).round() / 10.0;
    if (newValue != _lastPower) {
      log('solar power ${value.toStringAsFixed(1)}kW');
      _lastPower = newValue;
      _updateDisplay();
    }
  }

  Stopwatch _remyUpdateStopwatch;

  void _updateDisplay() {
    if (_lastPower == null)
      return;
    _cloudbit.setNumberVolts(_lastPower.clamp(0.0, 5.0));
    if (_remyUpdateStopwatch == null || _remyUpdateStopwatch.elapsed > remyUpdatePeriod) {
      if (_lastPower > 4.0)
        remy.pushButtonById('weatherBright');
      else if (_lastPower > 0.1)
        remy.pushButtonById('weatherDim');
      else
        remy.pushButtonById('weatherDark');
      _remyUpdateStopwatch ??= new Stopwatch();
      _remyUpdateStopwatch.start();
      _remyUpdateStopwatch.reset();
    }
  }

  bool _lastMotionSensorValue;
  bool _motionSensorConnected = false;
  Timer _motionStoppedTimer;

  void _motionSensor(int value) {
    final bool lastConnected = _motionSensorConnected;
    _motionSensorConnected = value != null;
    if (_motionSensorConnected != lastConnected)
      log('${_motionSensorConnected ? 'connected to' : 'disconnected from'} family room solar display cloudbit');
    if (value == null) {
      _motionStoppedTimer?.cancel();
      _motionStoppedTimer = null;
      _motionStream.add(null);
      _lastMotionSensorValue = null;
      return;
    }
    final bool newMotionSensorValue = value >= 512.0;
    if (_lastMotionSensorValue != newMotionSensorValue) {
      if (newMotionSensorValue) {
        _motionStoppedTimer?.cancel();
        _motionStoppedTimer = null;
        _motionStream.add(true);
      } else {
        _motionStoppedTimer = new Timer(motionIdleDuration, () {
          _motionStoppedTimer = null;
          _motionStream.add(false);
        });
      }
      _lastMotionSensorValue = newMotionSensorValue;
    }
  }

  void _motionRemyProxy(bool value) {
    if (value == null)
      return;
    if (value) {
      log('room is occupied');
      remy.pushButtonById('houseSensorFamilyRoomOccupied');
    } else {
      log('no motion detected');
      remy.pushButtonById('houseSensorFamilyRoomIdle');
    }
  }
}
