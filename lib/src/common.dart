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

  @protected
  void log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
