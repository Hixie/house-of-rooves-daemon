import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class LaundryRoomModel extends Model {
  LaundryRoomModel(this.cloud, this.remy, this.tts, String laundryId, { LogCallback onLog }) : super(onLog: onLog) {
    log('connecting to laundry room cloudbit ($laundryId)');
    _cloudbit = cloud.getDevice(laundryId);
    BitDemultiplexer laundryBits = new BitDemultiplexer(_cloudbit.values, 3, onDebugObserver: _handleBits);
    _bit1Subscription = laundryBits[1].transform(debouncer(const Duration(seconds: 1))).listen(_handleDoneLedBit); // 10 - Done
    _bit2Subscription = laundryBits[2].transform(debouncer(const Duration(milliseconds: 500))).listen(_handleSensingLedBit); // 20 - Sensing
    _bit3Subscription = laundryBits[3].transform(debouncer(const Duration(seconds: 2))).listen(_handleDryerBit); // 40 - Dryer
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-led-on').listen(_handleLed));
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-dryer-full').listen(_handleDryerFull));
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-announce-done').listen(_handleAnnounceDone));
    if (remy.hasNotification('laundry-status-washer-on')) {
      log('received laundry-status-washer-on on startup; restarting washer timer');
      washerRunning = true;
    }
    if (remy.hasNotification('laundry-status-dryer-on')) {
      log('received laundry-status-dryer-on on startup; restarting dryer timer');
      dryerRunning = true;
    }
    log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final TextToSpeechServer tts;

  CloudBit _cloudbit;
  StreamSubscription<bool> _bit1Subscription;
  StreamSubscription<bool> _bit2Subscription;
  StreamSubscription<bool> _bit3Subscription;
  Set<StreamSubscription<dynamic>> _miscSubscriptions = new HashSet<StreamSubscription<dynamic>>();

  static const Duration _kMinWasherCycleDuration = const Duration(minutes: 15);
  static const Duration _kMaxWasherCycleDuration = const Duration(hours: 4);
  static const Duration _kMinDryerCycleDuration = const Duration(minutes: 10);

  Timer _washerTimeout;

  void dispose() {
    _bit1Subscription.cancel();
    _bit2Subscription.cancel();
    _bit3Subscription.cancel();
    for (StreamSubscription<bool> subscription in _miscSubscriptions)
      subscription.cancel();
    _washerTimeout?.cancel();
  }

  int _lastValue;
  void _handleBits(int value) {
    if (_lastValue != value)
      log('decomposed sensor value: 0b${value.toRadixString(2).padLeft(4, '0')} (0x${value.toRadixString(16).padLeft(2, '0')})');
    _lastValue = value;
  }

  void _handleSensingLedBit(bool value) { // washer sensing LED bit
    log(value ? 'detected washer sensing LED on' : 'detected washer sensing LED off');
    if (value == true)
      washerRunning = true;
  }

  void _handleDoneLedBit(bool value) { // washer done LED bit
    log(value ? 'detected washer done LED on' : 'detected washer done LED off');
    if (value == true)
      washerRunning = false;
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

  // TODO(ianh): I need to move more of this logic over to remy.

  bool get washerRunning => _washerStopwatch.isRunning;
  Stopwatch _washerStopwatch = new Stopwatch();
  set washerRunning(bool value) {
    if (washerRunning == value)
      return;
    _washerTimeout?.cancel();
    _washerTimeout = null;
    if (value) {
      _washerStopwatch.reset();
      _washerStopwatch.start();
      log('washer started');
      remy.pushButtonById('laundryAutomaticWasherStarted');
      remy.pushButtonById('laundryAutomaticNone');
      _washerTimeout = new Timer(_kMaxWasherCycleDuration, _resetWasher);
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

  void _resetWasher() {
    // just in case we missed the "done" message
    assert(washerRunning);
    washerRunning = false;
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

  bool _announce;
  void _handleAnnounceDone(bool value) {
    if (value == null || value == _announce)
      return;
    bool oldValue = _announce;
    _announce = value;
    if (oldValue == null || !_announce)
      return;
    log('received laundry-announce-done');
    tts.audioIcon('laundry');
  }
}
