import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class ShowerDayModel extends Model {
  ShowerDayModel(this.cloud, this.remy, String showerDayId, { LogCallback onLog }) : super(onLog: onLog) {
    log('connecting to shower day cloudbit ($showerDayId)');
    _cloudbit = cloud.getDevice(showerDayId);
    _buttonStream = new AlwaysOnWatchStream<bool>();
    _subscriptions.add(_cloudbit.values.listen(_showerDayButton));
    _subscriptions.add(remy.getStreamForNotification('shower-day').listen(_handleRemyShowerState));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'shower day button', slop: 255.0, reportingThreshold: 10.0)));
    _subscriptions.add(_buttonStream.listen(_buttonRemyProxy));
    log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;

  CloudBit _cloudbit;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();
  WatchStream<bool> _buttonStream;

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  bool _buttonConnected = false;
  bool _showerDayStatus;

  void _showerDayButton(int value) {
    final bool lastConnected = _buttonConnected;
    _buttonConnected = value != null;
    if (_buttonConnected != lastConnected) {
      log('${_buttonConnected ? 'connected to' : 'disconnected from'} shower day cloudbit');
      if (_buttonConnected && _showerDayStatus != null)
        _updateCloudbit();
    }
    if (value == null) {
      _buttonStream.add(null);
      return;
    }
    _buttonStream.add(value >= 512.0);
  }

  void _buttonRemyProxy(bool value) {
    if (value == null)
      return;
    if (value) {
      log('shower day button pressed');
      remy.pushButtonById('showerDayCleanButton');
    }
  }

  void _handleRemyShowerState(bool showerDay) {
    if (showerDay == null)
      return;
    log('received shower day notification change - ${showerDay ? 'dirty' : 'clean'}');
    _showerDayStatus = showerDay;
    _updateCloudbit();
  }

  void _updateCloudbit() {
    log('sending status to shower day display - ${_showerDayStatus ? 'green (needs shower)' : 'red (no shower needed)'}');
    _cloudbit.setValue(_showerDayStatus ? 1023 : 0);
  }
}
