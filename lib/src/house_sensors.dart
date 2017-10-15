import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

class HouseSensorsModel {
  HouseSensorsModel(this.cloud, this.remy, String houseSensorsId, { this.onLog }) {
    _log('connecting to house sensors cloudbit ($houseSensorsId)');
    _cloudbit = cloud.getDevice(houseSensorsId);
    _subscriptions.add(_cloudbit.values.listen((int value) { _trackConnection(value != null); }));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: _log, name: 'house sensors', slop: 30.0, reportingThreshold: 1.0)));
    BitDemultiplexer houseSensorsBits = new BitDemultiplexer(_cloudbit.values, 3);
    _frontDoor = houseSensorsBits[1].transform(debouncer(longDebounceDuration)).transform(inverter); // 10
    _garageDoor = houseSensorsBits[2].transform(debouncer(shortDebounceDuration)).transform(inverter); // 20
    _backDoor = houseSensorsBits[3].transform(debouncer(shortDebounceDuration)).transform(inverter); // 40
    _subscriptions.add(frontDoor.listen(_getDoorRemyProxy('front', 'Front')));
    _subscriptions.add(garageDoor.listen(_getDoorRemyProxy('garage', 'Garage')));
    _subscriptions.add(backDoor.listen(_getDoorRemyProxy('back', 'Back')));
    _timer = new Timer.periodic(updatePeriod, _updateOutput);
    _log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final Logger onLog;

  static const Duration shortDebounceDuration = const Duration(milliseconds: 500);
  static const Duration longDebounceDuration = const Duration(milliseconds: 1500);
  static const Duration updatePeriod = const Duration(seconds: 10);

  Stream<bool> get frontDoor => _frontDoor;
  Stream<bool> _frontDoor;
  Stream<bool> get garageDoor => _garageDoor;
  Stream<bool> _garageDoor;
  Stream<bool> get backDoor => _backDoor;
  Stream<bool> _backDoor;

  CloudBit _cloudbit;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();
  Timer _timer;

  void dispose() {
    _timer.cancel();
    _timer = null;
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  StreamHandler<bool> _getDoorRemyProxy(String uiName, String remyName) {
    return (bool value) {
      _log(value ? '$uiName door open' : '$uiName door closed');
      remy.pushButtonById('houseSensor${remyName}Door${value ? "Open" : "Closed"}');
    };
  }

  bool _connected;

  void _trackConnection(bool value) {
    if (value != _connected) {
      _connected = value;
      _updateOutput(_timer);
    }
  }

  void _updateOutput(Timer timer) {
    assert(timer != null);
    assert(timer == _timer);
    _cloudbit.setBooleanValue(_connected, silent: true);
  }

  void _log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
