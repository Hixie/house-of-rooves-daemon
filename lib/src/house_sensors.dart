import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'message_center.dart';
import 'database/database.dart';
import 'database/adaptors.dart';

class HouseSensorsModel extends Model {
  HouseSensorsModel(this._cloudbit, this.dnsmasq, this.remy, this.messageCenter, this.tts, { LogCallback onLog }) : super(onLog: onLog) {
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'house sensors', slop: 30.0, reportingThreshold: 1.0)));
    BitDemultiplexer houseSensorsBits = new BitDemultiplexer(_cloudbit.values, 3);
    _frontDoor = houseSensorsBits[1].transform(debouncer(longDebounceDuration)).transform(inverter); // 10
    _garageDoor = houseSensorsBits[2].transform(debouncer(shortDebounceDuration)).transform(inverter); // 20
    _backDoor = houseSensorsBits[3].transform(debouncer(shortDebounceDuration)).transform(inverter); // 40
    _car = dnsmasq['car'];
    _carey = dnsmasq['carey-phone.family.rooves.house'];
    _ian = dnsmasq['ianh-android-phone-work.family.rooves.house'];
    _subscriptions.add(frontDoor.listen(_getDoorRemyProxy('front', 'Front', icon: 'front-door')));
    _subscriptions.add(garageDoor.listen(_getDoorRemyProxy('garage', 'Garage', hudTimeout: const Duration(seconds: 60))));
    _subscriptions.add(backDoor.listen(_getDoorRemyProxy('back', 'Back', hudTimeout: const Duration(seconds: 10))));
    _subscriptions.add(car.listen(_getPositionRemyProxy('car', 'carActive', 'carInactive')));
    _subscriptions.add(carey.listen(_getPositionRemyProxy('carey', 'careyHome', 'careyNotHome')));
    _subscriptions.add(ian.listen(_getPositionRemyProxy('ian', 'ianHome', 'ianNotHome')));
    _cloudbit.setBooleanValue(true);
    log('model initialised');
  }

  final CloudBit _cloudbit;
  final DnsMasqMonitor dnsmasq;
  final RemyMultiplexer remy;
  final MessageCenter messageCenter;
  final TextToSpeechServer tts;

  static const Duration shortDebounceDuration = const Duration(milliseconds: 500);
  static const Duration longDebounceDuration = const Duration(milliseconds: 1500);
  static const Duration updatePeriod = const Duration(seconds: 10);

  // from alarm system wires
  Stream<bool> get frontDoor => _frontDoor;
  Stream<bool> _frontDoor;
  Stream<bool> get garageDoor => _garageDoor;
  Stream<bool> _garageDoor;
  Stream<bool> get backDoor => _backDoor;
  Stream<bool> _backDoor;

  // from DNS probing
  Stream<bool> get car => _car;
  Stream<bool> _car;
  Stream<bool> get carey => _carey;
  Stream<bool> _carey;
  Stream<bool> get ian => _ian;
  Stream<bool> _ian;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  StreamHandler<bool> _getDoorRemyProxy(String lowerName, String upperName, { Duration hudTimeout, String icon }) {
    HudMessage hud = messageCenter.createHudMessage('$upperName door is open', timeout: hudTimeout, reminder: const Duration(minutes: 10));
    return (bool value) {
      if (privateMode)
        return;
      log(value ? '$lowerName door open' : '$lowerName door closed');
      remy.pushButtonById('houseSensor${upperName}Door${value ? "Open" : "Closed"}');
      hud.enabled = value;
      if ((icon != null) && value && !muted) {
        log('playing $icon sound');
        tts.audioIcon(icon);
      }
    };
  }

  StreamHandler<bool> _getPositionRemyProxy(String label, String trueButton, String falseButton) {
    return (bool value) {
      if (privateMode)
        return;
      log(value ? '$label detected' : '$label detection expired');
      remy.pushButtonById(value ? trueButton : falseButton);
    };
  }

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }
}

class HouseSensorsDataAdaptor extends DataAdaptor {
  HouseSensorsDataAdaptor({int tableId, this.model}) : assert(model != null), super(tableId);

  final HouseSensorsModel model;
  Set<StreamSubscription<bool>> _subscriptions = <StreamSubscription<bool>>{};

  @override
  void start(Database database) {
    assert(_subscriptions.isEmpty);
    super.start(database);
    _subscriptions.add(model.frontDoor.listen(_handleUpdateFrontDoor));
    _subscriptions.add(model.garageDoor.listen(_handleUpdateGarageDoor));
    _subscriptions.add(model.backDoor.listen(_handleUpdateBackDoor));
  }

  bool _frontDoor;
  bool _garageDoor;
  bool _backDoor;

  void _handleUpdateFrontDoor(bool bit) {
    _frontDoor = bit;
    _handleUpdate();
  }

  void _handleUpdateGarageDoor(bool bit) {
    _garageDoor = bit;
    _handleUpdate();
  }

  void _handleUpdateBackDoor(bool bit) {
    _backDoor = bit;
    _handleUpdate();
  }

  void _handleUpdate() {
    if (_frontDoor == null || _garageDoor == null || _backDoor == null) {
      _debounce(0xFF);
      return;
    }
    int data = (_frontDoor ? 0x01 : 0x00)
             | (_garageDoor ? 0x02 : 0x00)
             | (_backDoor ? 0x04 : 0x00);
    _debounce(data);
  }

  int _last;

  void _debounce(int next) {
    if (_last != next) {
      write(Uint8List.fromList(<int>[next]));
      _last = next;
    }
  }

  @override
  void end() {
    for (final StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
    _subscriptions.clear();
    super.end();
  }
}
