import 'package:home_automation_tools/all.dart';
import 'package:meta/meta.dart';

abstract class Model {
  Model({ this.onLog });

  final LogCallback onLog;

  @protected
  void log(String message) {
    if (onLog != null)
      onLog(message);
  }
}
