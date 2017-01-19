import 'dart:async';
import 'dart:collection';

import 'package:dart-home-automation-tools/lib/all.dart';

typedef void LaundryRoomLog(String message);

class LaundryRoomModel {
  LaundryRoomModel(this.cloud, this.remy, String laundryId, { this.onLog }) {
    _log('connecting to laundry room cloudbit ($laundryId)');
    _cloudbit = cloud.getDevice(laundryId);
    _miscSubscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: _log, name: 'laundry', slop: 25.0, reportingThreshold: 1.0)));
    BitDemultiplexer laundryBits = new BitDemultiplexer(_cloudbit.values, 4);
    _bit1Subscription = laundryBits[1].transform(debouncer(const Duration(seconds: 2))).listen(_handleDoneLedBit); //  5 - Done
    _bit2Subscription = laundryBits[2].transform(debouncer(const Duration(seconds: 2))).listen(_handleSensingLedBit); // 10 - Sensing
    _bit3Subscription = laundryBits[3].transform(debouncer(const Duration(milliseconds: 200))).listen(_handleButtonBit); // 20 - Button
    _bit4Subscription = laundryBits[4].transform(debouncer(const Duration(seconds: 2))).listen(_handleDryerBit); // 40 - Dryer
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-led-on').listen(_handleLed));
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-dryer-full').listen(_handleDryerFull));
    if (remy.hasNotification('laundry-status-washer-on')) {
      _log('restarting washer timer');
      washerRunning = true;
    }
    if (remy.hasNotification('laundry-status-dryer-on')) {
      _log('restarting dryer timer');
      dryerRunning = true;
    }
    _log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final LaundryRoomLog onLog;

  CloudBit _cloudbit;
  StreamSubscription<bool> _bit1Subscription;
  StreamSubscription<bool> _bit2Subscription;
  StreamSubscription<bool> _bit3Subscription;
  StreamSubscription<bool> _bit4Subscription;
  Set<StreamSubscription<dynamic>> _miscSubscriptions = new HashSet<StreamSubscription<dynamic>>();

  static const Duration _kMinWasherCycleDuration = const Duration(minutes: 15);
  static const Duration _kMinDryerCycleDuration = const Duration(minutes: 10);

  void dispose() {
    _bit1Subscription.cancel();
    _bit2Subscription.cancel();
    _bit3Subscription.cancel();
    _bit4Subscription.cancel();
    for (StreamSubscription<bool> subscription in _miscSubscriptions)
      subscription.cancel();
  }

  void _handleDoneLedBit(bool value) {
    // washer done LED bit
    _log(value ? 'detected washer done LED on' : 'detected washer done LED off');
    if (value == true)
      washerRunning = false;
  }

  void _handleSensingLedBit(bool value) {
    // washer sensing LED bit
    _log(value ? 'detected washer sensing LED on' : 'detected washer sensing LED off');
    if (value == true)
      washerRunning = true;
  }

  void _handleButtonBit(bool value) {
    // button bit
    _log(value ? 'detected button down' : 'detected button up');
    if (value == true)
      _handleButtonPushed();
  }

  void _handleDryerBit(bool value) {
    // dryer knob bit
    _log(value ? 'detected dryer knob on cycle' : 'detected dryer knob off cycle');
    if (value != null)
      dryerRunning = value;
  }

  void _handleLed(bool led) {
    if (led == null)
      return;
    _log('received laundry-led-on notification change - ${led ? 'active' : 'now inactive'}');
    _log('switching LED wire ${led ? 'on' : 'off'}');
    _cloudbit.setValue(led ? 1023 : 0);
  }

  bool get washerRunning => _washerStopwatch.isRunning;
  Stopwatch _washerStopwatch = new Stopwatch();
  set washerRunning(bool value) {
    if (washerRunning == value)
      return;
    if (value) {
      _washerStopwatch.reset();
      _washerStopwatch.start();
      _log('washer started');
      remy.pushButtonById('laundryAutomaticWasherStarted');
      remy.pushButtonById('laundryAutomaticNone');
    } else {
      _washerStopwatch.stop();
      if (_washerStopwatch.elapsed >= _kMinWasherCycleDuration) {
        _log('washer finished');
        remy.pushButtonById('laundryAutomaticWasherClean');
      } else {
        _log('washer stopped early');
        remy.pushButtonById('laundryAutomaticWasherFull');
      }
    }
  }

  bool get dryerFull => _dryerFull;
  bool _dryerFull = false;
  void _handleDryerFull(bool value) {
    if (value == null)
      return;
    _log('received notification change - laundry-dryer-full ${value ? 'active' : 'now inactive'}');
    _log(value ? 'dryer must be full' : 'dryer must be empty');
    _dryerFull = value;
  }

  bool get dryerRunning => _dryerStopwatch.isRunning;
  Stopwatch _dryerStopwatch = new Stopwatch();
  set dryerRunning(bool value) {
    if (dryerRunning == value)
      return;
    if (value) {
      _dryerStopwatch.reset();
      _dryerStopwatch.start();
      _log('dryer started');
      if (dryerFull)
        remy.pushButtonById('laundryAutomaticCleanLaundryPending');
      if (!washerRunning)
        remy.pushButtonById('laundryAutomaticWasherEmpty');
      remy.pushButtonById('laundryAutomaticDryerStarted');
    } else {
      _dryerStopwatch.stop();
      if (_dryerStopwatch.elapsed >= _kMinDryerCycleDuration) {
        _log('dryer finished');
        remy.pushButtonById('laundryAutomaticDryerClean');
      } else {
        _log('dryer stopped early');
        remy.pushButtonById('laundryAutomaticDryerFull');
      }
    }
  }

  void _handleButtonPushed() {
    _log('button pushed');
    if (dryerRunning && !washerRunning) {
      remy.pushButtonById('laundryAutomaticWasherClean');
    } else {
      remy.pushButtonById('laundryAutomaticLots');
    }
  }

  void _log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
