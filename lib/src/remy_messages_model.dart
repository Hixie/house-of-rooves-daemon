import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';
import 'message_center.dart';

class RemyMessagesModel extends Model {
  RemyMessagesModel(this.messageCenter, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(remy.notifications.listen(_handleNotifications));
    _subscriptions.add(remy.getStreamForNotification('i-did-that').listen(_handleRemyDidThat));
    log('model initialised');
  }

  final MessageCenter messageCenter;
  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  static const Duration didThatWindow = const Duration(seconds: 55);

  RemyNotification _lastMessage;
  DateTime _lastMessageTimestamp;

  void _handleNotifications(RemyNotification notification) {
    if (notification.classes.contains('automatic'))
      return;
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
    bool visual = !notification.classes.contains('nomsg');
    bool verbal = notification.escalationLevel >= 3 && !muted;
    bool beep = notification.escalationLevel != 2 && !muted;
    if (visual || verbal) {
      log('announcing "${notification.label}" (escalation level ${notification.escalationLevel}${ verbal ? "" : "; text only" })');
    } else if (beep) {
      log('beeping to indicate presence of "${notification.label}"');
    }
    if (visual || verbal || beep) {
      messageCenter.announce(
        label,
        notification.escalationLevel,
        verbal: verbal,
        auditoryIcon: beep,
        visual: visual,
      ).then((Null value) {
        if (verbal)
          log('announcement for "${notification.label}" complete.');
      });
    }
    if (verbal || visual)
      _lastMessage = null;
    if (verbal) {
      _lastMessage = notification;
      _lastMessageTimestamp = new DateTime.now();
    }
  }

  void _handleRemyDidThat(bool state) {
    if (!state)
      return;
    remy.pushButtonById('iDidThatAcknowledged');
    if (_lastMessage != null && new DateTime.now().difference(_lastMessageTimestamp) < didThatWindow) {
      RemyNotification lastMessage = _lastMessage;
      _lastMessage = null;
      for (RemyMessage message in remy.currentState.messages) {
        if (message.label == lastMessage.label) {
          if (message.buttons.isEmpty) {
            log('unfortunately, the last message ("${lastMessage.label}") had no buttons.');
            return;
          }
          remy.pushButton(message.buttons.first);
          return;
        }
      }
    } else {
      log('heard "I did that!" with no recent message.');
    }
  }
}
