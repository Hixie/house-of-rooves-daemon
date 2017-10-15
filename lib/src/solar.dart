import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class SolarModel {
  SolarModel(this.cloud, this.monitor, this.remy, String solarId, { this.onLog }) {
    _log('connecting to solar display cloudbit ($solarId)');
    _cloudbit = cloud.getDevice(solarId);
    _motionStream = new AlwaysOnWatchStream<bool>();
    _subscriptions.add(_cloudbit.values.listen(_motionSensor));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: _log, name: 'family room solar display', slop: 255.0, reportingThreshold: 10.0)));
    _subscriptions.add(monitor.power.listen(_power));
    _subscriptions.add(motionStream.listen(_motionRemyProxy));
    _updater = new Timer.periodic(refreshPeriod, _updateDisplay);
    _log('model initialised');
  }

  final LittleBitsCloud cloud;
  final SunPowerMonitor monitor;
  final RemyMultiplexer remy;
  final LogCallback onLog;

  static const Duration refreshPeriod = const Duration(seconds: 15); // cannot be more than half of 30 seconds (the max time to send to cloudbit)
  static const Duration motionIdleDuration = const Duration(minutes: 15);
  static const Duration remyUpdatePeriod = const Duration(minutes: 60);

  WatchStream<bool> get motionStream => _motionStream;
  WatchStream<bool> _motionStream;

  CloudBit _cloudbit;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();
  Timer _updater;

  void dispose() {
    _motionStoppedTimer?.cancel();
    _motionStream.close();
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
    _updater.cancel();
  }

  double _lastPower;

  void _power(double value) {
    if (value == null)
      return;
    double newValue = (value * 10.0).round() / 10.0;
    if (newValue != _lastPower) {
      _log('solar power ${value.toStringAsFixed(1)}kW');
      _lastPower = newValue;
      _updateDisplay(_updater);
    }
  }

  Stopwatch _remyUpdateStopwatch;

  void _updateDisplay(Timer timer) {
    if (_lastPower == null)
      return;
    _cloudbit.setNumberVolts(_lastPower.clamp(0.0, 5.0), duration: refreshPeriod * 2.0);
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
      _log('${_motionSensorConnected ? 'connected to' : 'disconnected from'} family room solar display cloudbit');
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
      _log('room is occupied');
      remy.pushButtonById('houseSensorFamilyRoomOccupied');
    } else {
      _log('no motion detected');
      remy.pushButtonById('houseSensorFamilyRoomIdle');
    }
  }

  void _log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
