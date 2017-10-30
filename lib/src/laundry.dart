import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class LaundryRoomModel extends Model {
  LaundryRoomModel(this.cloud, this.remy, String laundryId, { LogCallback onLog }) : super(onLog: onLog) {
    log('connecting to laundry room cloudbit ($laundryId)');
    _cloudbit = cloud.getDevice(laundryId);
    // _miscSubscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'laundry', slop: 1023.0 * 2.0 / 99, reportingThreshold: 1.0)));
    BitDemultiplexer laundryBits = new BitDemultiplexer(_cloudbit.values, 4);
    _bit2Subscription = laundryBits[1].transform(debouncer(const Duration(seconds: 2))).listen(_handleSensingLedBit); // 5 - Sensing
    _bit1Subscription = laundryBits[2].transform(debouncer(const Duration(seconds: 5))).listen(_handleDoneLedBit); //  10 - Done
    _bit3Subscription = laundryBits[3].transform(debouncer(const Duration(milliseconds: 200))).listen(_handleButtonBit); // 20 - Button
    _bit4Subscription = laundryBits[4].transform(debouncer(const Duration(seconds: 2))).listen(_handleDryerBit); // 40 - Dryer
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-led-on').listen(_handleLed));
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-dryer-full').listen(_handleDryerFull));
    if (remy.hasNotification('laundry-status-washer-on')) {
      log('restarting washer timer');
      washerRunning = true;
    }
    if (remy.hasNotification('laundry-status-dryer-on')) {
      log('restarting dryer timer');
      dryerRunning = true;
    }
    log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;

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

  void _handleSensingLedBit(bool value) { // washer sensing LED bit
    // This bit is inverted; true means it's off, false means its on.
    log(value ? 'detected washer sensing LED off' : 'detected washer sensing LED on');
    if (value == false)
      washerRunning = true;
  }

  void _handleDoneLedBit(bool value) { // washer done LED bit
    // This bit is inverted; true means it's off, false means its on.
    log(value ? 'detected washer done LED off' : 'detected washer done LED on');
    if (value == false)
      washerRunning = false;
  }

  void _handleButtonBit(bool value) { // button bit
    // True means it's being pressed.
    log(value ? 'detected button down' : 'detected button up');
    if (value == true)
      _handleButtonPushed();
  }

  void _handleDryerBit(bool value) { // dryer knob bit
    // True means the knob is currently in an "on" cycle, false means it's in an "off" cycle.
    log(value ? 'detected dryer knob on cycle' : 'detected dryer knob off cycle');
    dryerRunning = value;
  }

  bool get ledStatus => _ledStatus;
  bool _ledStatus;
  void _handleLed(bool led) {
    if (led == null || led == _ledStatus)
      return;
    _ledStatus = led;
    log('received laundry-led-on notification change - ${led ? 'active' : 'now inactive'}');
    log('switching LED wire ${led ? 'on' : 'off'}');
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
      log('washer started');
      remy.pushButtonById('laundryAutomaticWasherStarted');
      remy.pushButtonById('laundryAutomaticNone');
    } else {
      _washerStopwatch.stop();
      if (_washerStopwatch.elapsed >= _kMinWasherCycleDuration) {
        log('washer finished');
        remy.pushButtonById('laundryAutomaticWasherClean');
      } else {
        log('washer stopped early');
        remy.pushButtonById('laundryAutomaticWasherFull');
      }
    }
  }

  bool get dryerFull => _dryerFull;
  bool _dryerFull = false;
  void _handleDryerFull(bool value) {
    if (value == null)
      return;
    log('received notification change - laundry-dryer-full ${value ? 'active' : 'now inactive'}');
    log(value ? 'dryer must be full' : 'dryer must be empty');
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
      log('dryer started');
      if (dryerFull)
        remy.pushButtonById('laundryAutomaticCleanLaundryPending');
      if (!washerRunning)
        remy.pushButtonById('laundryAutomaticWasherEmpty');
      remy.pushButtonById('laundryAutomaticDryerStarted');
    } else {
      _dryerStopwatch.stop();
      if (_dryerStopwatch.elapsed >= _kMinDryerCycleDuration) {
        log('dryer finished');
        remy.pushButtonById('laundryAutomaticDryerClean');
      } else {
        log('dryer stopped early');
        remy.pushButtonById('laundryAutomaticDryerFull');
      }
    }
  }

  void _handleButtonPushed() {
    log('button pushed');
    if (!washerRunning) {
      if (_ledStatus) {
        log('button pushed while washer idle and LED on; interpreting this as a notification that the washer is empty');
        remy.pushButtonById('laundryAutomaticWasherEmpty');
      } else {
        log('button pushed while washer idle and LED off; interpreting this as a notification that the washer has clean wet laundry');
        remy.pushButtonById('laundryAutomaticWasherClean');
      }
    } else {
      log('button pushed while washer running; interpreting this as a notification that the washer finished');
      washerRunning = false;
    }
  }
}
