import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class LaundryRoomModel extends Model {
  LaundryRoomModel(this.remy, this.tts, { LogCallback onLog }) : super(onLog: onLog) {
    _miscSubscriptions.add(remy.getStreamForNotification('laundry-announce-done').listen(_handleAnnounceDone));
    log('model initialised');
  }

  final RemyMultiplexer remy;
  final TextToSpeechServer tts;

  Set<StreamSubscription<dynamic>> _miscSubscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _miscSubscriptions)
      subscription.cancel();
  }

  bool _announce;
  void _handleAnnounceDone(bool value) {
    if (value == null || value == _announce)
      return;
    bool oldValue = _announce;
    _announce = value;
    if (oldValue == null || !_announce)
      return;
    log('received laundry-announce-done');
    tts.audioIcon('laundry');
  }
}
