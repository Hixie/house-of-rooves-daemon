import 'dart:async';
import 'dart:collection';

import 'package:dart-home-automation-tools/lib/all.dart';

class HouseSensorsModel {
  HouseSensorsModel(this.cloud, this.remy, String houseSensorsId, { this.onLog }) {
    _log('connecting to house sensors cloudbit ($houseSensorsId)');
    _cloudbit = cloud.getDevice(houseSensorsId);
    _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: _log, name: 'house sensors', slop: 50.0, reportingThreshold: 2.0)));
    BitDemultiplexer houseSensorsBits = new BitDemultiplexer(_cloudbit.values, 3);
    _frontDoor = houseSensorsBits[1].transform(debouncer(debounceDuration)).transform(inverter); // 10
    _garageDoor = houseSensorsBits[2].transform(debouncer(debounceDuration)).transform(inverter); // 20
    _backDoor = houseSensorsBits[3].transform(debouncer(debounceDuration)).transform(inverter); // 40
    _subscriptions.add(frontDoor.listen(_getDoorRemyProxy('front', 'Front')));
    _subscriptions.add(garageDoor.listen(_getDoorRemyProxy('garage', 'Garage')));
    _subscriptions.add(backDoor.listen(_getDoorRemyProxy('back', 'Back')));
    _log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final Logger onLog;

  static const Duration debounceDuration = const Duration(milliseconds: 200);

  Stream<bool> get frontDoor => _frontDoor;
  Stream<bool> _frontDoor;
  Stream<bool> get garageDoor => _garageDoor;
  Stream<bool> _garageDoor;
  Stream<bool> get backDoor => _backDoor;
  Stream<bool> _backDoor;

  CloudBit _cloudbit;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  StreamHandler<bool> _getDoorRemyProxy(String uiName, String remyName) {
    return (bool value) {
      _log(value ? '$uiName door open' : '$uiName door closed');
      remy.pushButtonById('houseSensor${remyName}Door${value ? "Open" : "Closed"}');
    };
  }

  void _log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
