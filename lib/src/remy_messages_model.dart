import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'message_center.dart';

class RemyMessagesModel extends Model {
  RemyMessagesModel(this.messageCenter, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(remy.notifications.listen(_handleNotifications));
    
    log('model initialised');
  }

  final MessageCenter messageCenter;
  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  void _handleNotifications(RemyNotification notification) {
    log('announcing "${notification.label}" (escalation level ${notification.escalationLevel})');
    String label;
    switch (notification.escalationLevel) {
      case 9:
        label = 'Alert! Alert! ${notification.label} Alert! Alert! ${notification.label}';
        break;
      case 8:
      case 7:
      case 6:
        label = 'Attention! ${notification.label}';
        break;
      default:
        label = notification.label;
    }
    bool muted = notification.classes.contains('quiet');
    if (!notification.classes.contains('important')) {
      int hour = new DateTime.now().hour;
      if (hour > 23 || hour < 11)
        muted = true;
    }
    messageCenter.announce(
      label,
      notification.escalationLevel,
      verbal: notification.escalationLevel >= 3 && !muted,
      auditoryIcon: !muted,
      visual: !notification.classes.contains('nomsg'),
    ).then((Null value) {
      log('announcement for "${notification.label}" complete.');
    });
    // notification.buttons contains some buttons that can be pressed
    // TODO(ianh): remember the last mentioned button, if there's only one
    // TODO(ianh): Google Home "I did that" within a minute -> press that button
  }
}
