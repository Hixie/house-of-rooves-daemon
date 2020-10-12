import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class LeakMonitorModel extends Model {
  LeakMonitorModel(this.dataSource, this.remy, this.id, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(dataSource.output.listen(_handler));
    log('model initialised ($id)');
  }

  final ProcessMonitor dataSource;
  final RemyMultiplexer remy;
  final String id;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<dynamic> subscription in _subscriptions)
      subscription.cancel();
  }

  void _handler(int value) {
    if (value == null)
      return;
    if (value > 0)
      remy.pushButtonById('leakSensor${id}DetectingLeak');
    else
      remy.pushButtonById('leakSensor${id}Idle');
  }
}
