import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class ShowerDayModel extends Model {
  ShowerDayModel(this._cloudbit, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _buttonStream = new AlwaysOnWatchStream<bool>();
    _subscriptions.add(_cloudbit.values.listen(_showerDayButton));
    _subscriptions.add(_cloudbit.button.listen(_showerDayTinyButton));
    // _subscriptions.add(_cloudbit.values.listen(getAverageValueLogger(log: log, name: 'shower day button', slop: 255.0, reportingThreshold: 10.0)));
    _subscriptions.add(_buttonStream.listen(_buttonRemyProxy));
    _subscriptions.add(remy.getStreamForNotification('shower-day').listen(_handleRemyShowerState));
    log('model initialised');
  }

  final RemyMultiplexer remy;

  final CloudBit _cloudbit;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();
  WatchStream<bool> _buttonStream;

  LedColor _color = LedColor.black;

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  bool _showerDayStatus;

  void _showerDayButton(int value) {
    if (value == null)
      return;
    _buttonStream.add(value >= 512.0);
  }

  void _showerDayTinyButton(bool value) {
    if (value == null)
      return;
    if (value) {
      _color = LedColor.values[(_color.index + 1) % LedColor.values.length];
      _cloudbit.setLedColor(_color);
    }
  }

  void _buttonRemyProxy(bool value) {
    if (value == null)
      return;
    if (value) {
      log('shower day button pressed (current state is $_showerDayStatus)');
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
