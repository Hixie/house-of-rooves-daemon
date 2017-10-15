import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

class ShowerDayModel {
  ShowerDayModel(this.cloud, this.remy, String showerDayId, { this.onLog }) {
    _log('connecting to shower day cloudbit ($showerDayId)');
    _cloudbit = cloud.getDevice(showerDayId);
    _buttonStream = new AlwaysOnWatchStream<bool>();
    _subscriptions.add(_cloudbit.values.listen(_showerDayButton));
    _subscriptions.add(remy.getStreamForNotification('shower-day').listen(_handleRemyShowerState));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: _log, name: 'shower day button', slop: 255.0, reportingThreshold: 10.0)));
    _subscriptions.add(_buttonStream.listen(_buttonRemyProxy));
    _log('model initialised');
  }

  final LittleBitsCloud cloud;
  final RemyMultiplexer remy;
  final Logger onLog;

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
      _log('${_buttonConnected ? 'connected to' : 'disconnected from'} shower day cloudbit');
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
      _log('shower day button pressed');
      remy.pushButtonById('showerDayCleanButton');
    }
  }

  void _handleRemyShowerState(bool showerDay) {
    if (showerDay == null)
      return;
    _log('received shower day notification change - ${showerDay ? 'dirty' : 'clean'}');
    _showerDayStatus = showerDay;
    _updateCloudbit();
  }

  void _updateCloudbit() {
    _log('sending status to shower day display - ${_showerDayStatus ? 'green (needs shower)' : 'red (no shower needed)'}');
    _cloudbit.setValue(_showerDayStatus ? 1023 : 0);
  }

  void _log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
