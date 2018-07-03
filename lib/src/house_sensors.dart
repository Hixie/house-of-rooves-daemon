import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'message_center.dart';

class HouseSensorsModel extends Model {
  HouseSensorsModel(this.cloud, this.remy, this.messageCenter, String houseSensorsId, { LogCallback onLog }) : super(onLog: onLog) {
    log('connecting to house sensors cloudbit ($houseSensorsId)');
    _cloudbit = cloud.getDevice(houseSensorsId);
    _subscriptions.add(_cloudbit.values.listen((int value) { _trackConnection(value != null); }));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'house sensors', slop: 30.0, reportingThreshold: 1.0)));
    BitDemultiplexer houseSensorsBits = new BitDemultiplexer(_cloudbit.values, 3);
    _frontDoor = houseSensorsBits[1].transform(debouncer(longDebounceDuration)).transform(inverter); // 10
    _garageDoor = houseSensorsBits[2].transform(debouncer(shortDebounceDuration)).transform(inverter); // 20
    _backDoor = houseSensorsBits[3].transform(debouncer(shortDebounceDuration)).transform(inverter); // 40
    _subscriptions.add(frontDoor.listen(_getDoorRemyProxy('front', 'Front')));
    _subscriptions.add(garageDoor.listen(_getDoorRemyProxy('garage', 'Garage', hudTimeout: const Duration(seconds: 60))));
    _subscriptions.add(backDoor.listen(_getDoorRemyProxy('back', 'Back', hudTimeout: const Duration(seconds: 10))));
    _timer = new Timer.periodic(updatePeriod, _updateOutput);
    log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final MessageCenter messageCenter;

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

  StreamHandler<bool> _getDoorRemyProxy(String lowerName, String upperName, { Duration hudTimeout }) {
    HudMessage hud = messageCenter.createHudMessage('$upperName door is open', timeout: hudTimeout, reminder: const Duration(minutes: 10));
    return (bool value) {
      log(value ? '$lowerName door open' : '$lowerName door closed');
      remy.pushButtonById('houseSensor${upperName}Door${value ? "Open" : "Closed"}');
      hud.enabled = value;
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
}
