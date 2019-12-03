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
    // Ideally we'd use our own metrics to determine AQI rather than the officially reported AQI metrics, but
    // for now, all our data sources provide official AQI metrics, so we use those.
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
      log('no recent data points available ($value)');
      remy.pushButtonById('airQualityUnknown');
    } else {
      log('$value  maximum AQI: $maxAqi');
      if (maxAqi < 70.0) {
        // 0-50 is theoretically the "good" range in the US.
        // In reality the range is relatively optimistic (things are bad before you reach 50).
        // We allow the range up to 70.0 because the Bay Area just has terrible air and we don't want to always show a warning.
        remy.pushButtonById('airQualityGood');
      } else if (maxAqi < 100.0) {
        // Officially 50-100 is "for some pollutants there may be a moderate health concern for a very small number of people".
        remy.pushButtonById('airQualityBad');
      } else if (maxAqi < 150.0) {
        // Officially 100-150 is "Unhealthy for Sensitive Groups", i.e. anyone who's ill, young, old...
        remy.pushButtonById('airQualityToxic1');
      } else if (maxAqi < 200.0) {
        // Officially 150-200 is "Everyone may begin to experience some adverse health effects".
        remy.pushButtonById('airQualityToxic2');
      } else {
        // Officially 200+ is "trigger a health alert signifying that everyone may experience more serious health effects".
        // Officially 300+ is "trigger health warnings of emergency conditions".
        remy.pushButtonById('airQualityToxic3');
      }
    }
  }
}
