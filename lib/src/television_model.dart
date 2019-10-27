import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'message_center.dart';

class TelevisionModel extends Model {
  TelevisionModel(this.tv, this.remy, this.messageCenter, { LogCallback onLog }) : super(onLog: onLog) {
    _identify();
    _updateStatus();
    _subscriptions.add(remy.getStreamForNotification('tv-on').listen(_handleRemyTvOn));
    _subscriptions.add(remy.getStreamForNotification('tv-off').listen(_handleRemyTvOff));
    _subscriptions.add(remy.getStreamForNotification('tv-off-countdown').listen(_handleRemyTvOffCountdown));
    _subscriptions.add(remy.getStreamForNotificationWithArgument('tv-input').listen(_handleRemyTvSwitchInput));
    _subscriptions.add(remy.getStreamForNotificationWithArgument('tv-on-input').listen(_handleRemyTvOnAndSwitchInput));
    _subscriptions.add(remy.getStreamForNotificationWithArgument('wake-on-lan').listen(_handleRemyWakeOnLan));
    _subscriptions.add(tv.connected.listen(_connected));
    log('model initialised');
  }

  final Television tv;
  final RemyMultiplexer remy;
  final MessageCenter messageCenter;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
    _timer?.cancel();
  }

  Future<Null> _identify() async {
    try {
      String name = await tv.name;
      String model = await tv.model;
      String version = await tv.softwareVersion;
      if (name != null || model != null || version != null)
        log('connected to TV named "$name", model $model, software version $version');
    } on TelevisionException catch (error) {
      log('failed to connect to TV: $error');
    }
  }

  Timer _timer;
  bool _checking = false;
  bool _lastPowerStatus;
  String _lastInputStatus;

  Future<Null> _updateStatus() async {
    _checking = true;
    _timer?.cancel();
    _timer = null;
    Duration nextDelay = const Duration(seconds: 10);
    if (!privateMode) {
      try {
        bool power;
        String input;
        switch ((await tv.input).source) {
          case TelevisionSource.analog:
          case TelevisionSource.analogAir:
          case TelevisionSource.analogCable:
          case TelevisionSource.digitalAir:
          case TelevisionSource.digitalCableOnePart:
          case TelevisionSource.digitalCableTwoPart:
            power = true;
            input = 'Channel';
            break;
          case TelevisionSource.hdmi1:
            power = true;
            input = 'Hdmi1';
            break;
          case TelevisionSource.hdmi2:
            power = true;
            input = 'Hdmi2';
            break;
          case TelevisionSource.hdmi3:
            power = true;
            input = 'Hdmi3';
            break;
          case TelevisionSource.hdmi4:
            power = true;
            input = 'Hdmi4';
            break;
          case TelevisionSource.input5:
          case TelevisionSource.composite:
          case TelevisionSource.component:
            power = true;
            input = 'Input5';
            break;
          case TelevisionSource.ethernet:
          case TelevisionSource.storage:
          case TelevisionSource.miracast:
          case TelevisionSource.bluetooth:
          case TelevisionSource.manual:
            power = true;
            input = 'Network';
            break;
          case TelevisionSource.unknown:
            power = true;
            nextDelay = const Duration(seconds: 2);
            break;
          case TelevisionSource.switching:
            power = true;
            nextDelay = const Duration(seconds: 1);
            break;
          case TelevisionSource.off:
            power = false;
            break;
        }
        if (power != null && power != _lastPowerStatus) {
          if (power) {
            remy.pushButtonById('tvOn');
          } else {
            remy.pushButtonById('tvOff');
          }
          _lastPowerStatus = power;
        }
        if (input != null && input != _lastInputStatus) {
          remy.pushButtonById('tvInput$input');
          _lastInputStatus = input;
        }
      } on TelevisionException catch (error) {
        log('unexpected response when updating television status: $error');
      }
    }
    _checking = false;
    _scheduleCheck(nextDelay);
  }

  void _connected(bool connected) {
    // Someone else in our process is trying to fiddle with the TV,
    // so we know there's a chance something will happen soon.
    // (If it's us, then _checking will be true and this will have
    // no effect.)
    if (connected)
      _scheduleCheck(const Duration(seconds: 1));
  }

  void _scheduleCheck(Duration delay) {
    if (_checking)
      return;
    _timer = new Timer(delay, _updateStatus);
  }

  Future<Null> _handleRemyTvOn(bool value) async {
    if (!value)
      return;
    try {
      log('turning the tv on');
      await tv.setPower(true);
      _scheduleCheck(const Duration(milliseconds: 10));
    } on TelevisionException catch (error) {
      log('unexpected response when switching television on: $error');
    } 
  }
  
  Future<Null> _handleRemyTvOff(bool value) async {
    if (!value)
      return;
    try {
      log('powering off the tv');
      await tv.setPower(false);
      _scheduleCheck(const Duration(milliseconds: 10));
    } on TelevisionException catch (error) {
      log('unexpected response when switching television off: $error');
    } 
  }
  
  Future<Null> _handleRemyTvOffCountdown(bool value) async {
    if (!value || !await _power)
      return;
    try {
      log('initiating 60 second countdown for tv power off - silent sequence start');
      await new Future<Null>.delayed(const Duration(seconds: 30));
      log('30 seconds remain on countdown for tv power off - visual sequence start');
      if (!await _power) {
        log('countdown aborted');
        return;
      }
      StringMessage message, clock;
      SpinnerMessage spinner;
      try {
        message = new StringMessage('TV shutdown sequence initiated.');
        messageCenter.show(message);
        spinner = new SpinnerMessage();
        messageCenter.show(spinner);
        clock = new StringMessage('COUNTDOWN START');
        messageCenter.show(clock);
        await new Future<Null>.delayed(const Duration(milliseconds: 250));
        for (int time = 30; time > 0; time -= 1) {
          clock.message = 'T-$time seconds';
          await new Future<Null>.delayed(const Duration(seconds: 1));
          if (!await _power) {
            log('countdown aborted at T-$time seconds');
            return;
          }
        }
      } finally {
        clock?.hide();
        spinner?.hide();
        message?.hide();
      }
      await tv.setPower(false);
      _scheduleCheck(const Duration(milliseconds: 10));
    } on TelevisionException catch (error) {
      log('unexpected response when performing television off countdown: $error');
    } 
  }

  Future<bool> get _power async {
    try {
      if (await tv.power)
        return true;
    } on TelevisionException {
    }
    return false;
  }
  
  Future<Null> _handleRemyTvSwitchInput(String value) async {
    if ((value.startsWith('hdmi') &&
         value.length == 5 &&
         (value == 'hdmi1' ||
          value == 'hdmi2' ||
          value == 'hdmi3' ||
          value == 'hdmi4')) ||
        (value == 'input5')) {
      try {
        TelevisionSource source;
        switch (value) {
          case 'hdmi1':
            source = TelevisionSource.hdmi1;
            break;
          case 'hdmi2':
            source = TelevisionSource.hdmi2;
            break;
          case 'hdmi3':
            source = TelevisionSource.hdmi3;
            break;
          case 'hdmi4':
            source = TelevisionSource.hdmi4;
            break;
          case 'input5':
            source = TelevisionSource.component;
            break;
        }
        assert(source != null);
        log('switching to input $value');
        await tv.setInput(new TelevisionChannel.fromSource(source));
        _scheduleCheck(const Duration(milliseconds: 10));
      } on TelevisionException catch (error) {
        log('unexpected response when switching television channel: $error');
      }
    } else {
      log('received invalid input request (with input "$value")');
    }
  }
  
  Future<Null> _handleRemyTvOnAndSwitchInput(String value) async {
    await _handleRemyTvOn(true);
    await _handleRemyTvSwitchInput(value);
  }
  
  Future<Null> _handleRemyWakeOnLan(String value) async {
    if (value.length != 12) {
      log('received invalid wake-on-lan request (with supposed MAC address "$value")');
      return;
    }
    Uint8List macAddress = new Uint8List(6);
    try {
      for (int index = 0; index < macAddress.length; index += 1)
        macAddress[index] = int.parse(value.substring(index * 2, index * 2 + 2), radix: 16);
    } on FormatException {
      log('received invalid wake-on-lan request (with supposed MAC address "$value")');
      return;
    }
    log('sending wake-on-lan packet to MAC address "$value"');
    await wakeOnLan(macAddress);
  }
}
