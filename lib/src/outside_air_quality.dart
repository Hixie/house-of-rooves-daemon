import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class OutsideAirQualityModel extends Model {
  OutsideAirQualityModel(this.dataSource, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(dataSource.dataStream.listen(_handler));
    log('model initialised');
  }

  final AirNowAirQualityMonitor dataSource;
  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  void _handler(MeasurementPacket value) {
    if (value == null)
      return;
    log(value.toString());
    double maxAqi = 0.0;
    int count = 0;
    DateTime now = new DateTime.now();
    for (AirQualityParameter parameter in value.parameters) {
      if (parameter.timestamp.difference(now) > const Duration(hours: 4))
        continue; // stale data
      if (parameter.aqi == null)
        continue; // no aqi metric
      maxAqi = math.max(maxAqi, parameter.aqi);
      count += 1;
    }
    if (count == 0) {
      log('no recent data points available');
      remy.pushButtonById('airQualityUnknown');
    } else {
      log('collected $count data points with a maximum air quality index of $maxAqi');
      if (maxAqi < 70.0) {
        remy.pushButtonById('airQualityGood'); // We allow the range up to 70.0 because the Bay Area just has terrible air and we don't want to always show a warning.
      } else if (maxAqi < 100.0) {
        remy.pushButtonById('airQualityBad');
      } else if (maxAqi < 150.0) {
        remy.pushButtonById('airQualityToxic1');
      } else if (maxAqi < 200.0) {
        remy.pushButtonById('airQualityToxic2');
      } else {
        remy.pushButtonById('airQualityToxic3');
      }
    }
  }
}
