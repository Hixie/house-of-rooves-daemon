import 'package:home_automation_tools/all.dart';
import 'package:meta/meta.dart';

abstract class Model {
  Model({ this.onLog });

  final LogCallback onLog;

  bool get privateMode => _privateMode;
  bool _privateMode = false;
  set privateMode(bool value) {
    if (value == _privateMode)
      return;
    _privateMode = value;
    if (privateMode) {
      log('private mode enabled');
    } else {
      log('private mode disabled');
    }
  }

  bool get muted => _muted;
  bool _muted = false;
  set muted(bool value) {
    if (value == _muted)
      return;
    _muted = value;
    if (muted) {
      log('sound muted');
    } else {
      log('sound enabled');
    }
  }

  @protected
  void log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
