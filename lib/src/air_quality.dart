import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';
import 'package:meta/meta.dart';

import 'common.dart';
import 'database/adaptors.dart';

class AirQualityModel extends Model {
  AirQualityModel(List<Stream<MeasurementPacket>> dataSources, this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    for (Stream<MeasurementPacket> dataSource in dataSources)
      _subscriptions.add(dataSource.listen(_handler));
    _timeSinceLastReport.start();
    _timeSinceRemyButtonPush.start();
    log('model initialised');
  }

  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  final Map<MeasurementStation, Map<Metric, Measurement>> _metrics = <MeasurementStation, Map<Metric, Measurement>>{};
  AirQualityParameter _worstParameter;
  Stopwatch _timeSinceLastReport = Stopwatch();
  Stopwatch _timeSinceRemyButtonPush = Stopwatch();
  Duration _timeBetweenReports = const Duration(minutes: 5); // at the start we give them more often, for debugging
  Duration _timeBetweenButtonPushes = const Duration(minutes: 90);
  static const Duration _maxTimeBetweenReports = const Duration(minutes: 20);

  bool _aqiDiffersSignificantly(AirQualityParameter a, AirQualityParameter b) {
    double delta = (a.aqi - b.aqi).abs();
    return delta > 5.0;
  }

  void _handler(MeasurementPacket value) {
    if (value == null)
      return;

    // update measurement cache
    for (Measurement parameter in value.parameters) {
      _metrics.putIfAbsent(parameter.station, () => <Metric, Measurement>{})[parameter.metric] = parameter;
    }

    // check all measurements for outside data
    double maxAqi = 0.0;
    AirQualityParameter worstParameter;
    DateTime now = new DateTime.now();
    for (Measurement parameter in _metrics.values.expand((Map<Metric, Measurement> station) => station.values)) {
      if (parameter is! AirQualityParameter)
        continue; // not air quality, won't have aqi
      if (!parameter.station.outside)
        continue; // we only care about outside data for outside air quality, obviously
      if (now.difference(parameter.timestamp) > const Duration(hours: 4))
        continue; // stale data
      AirQualityParameter airQualityParameter = parameter;
      final double aqi = airQualityParameter.aqi;
      if (aqi == null)
        continue; // no aqi metric
      if (aqi > maxAqi) {
        maxAqi = aqi;
        worstParameter = airQualityParameter;
      }
    }
    if (_worstParameter != worstParameter) {
      if (worstParameter == null) {
        _worstParameter = null;
        log('no recent data points available to determine outside air quality');
        remy.pushButtonById('airQualityUnknown');
      } else if (_worstParameter == null ||
                 _worstParameter.station != worstParameter.station ||
                 _aqiDiffersSignificantly(_worstParameter, worstParameter) ||
                 _timeSinceRemyButtonPush.elapsed > _timeBetweenButtonPushes) {
        _worstParameter = worstParameter;
        log('worst outside air quality measurement is currently ${metricToString(worstParameter.metric)}=$worstParameter at ${worstParameter.station}');
        if (maxAqi < 70.0) {
          // 0-50 is theoretically the "good" range in the US.
          // In reality the range is relatively optimistic (things are bad before you reach 50).
          // We allowed up to 70.0 because the Bay Area just has terrible air and we don't want to always show a warning.
          // It's very common for air quality to reach the high sixties.
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
        _timeSinceRemyButtonPush.reset();
      }
    }

    if (_timeSinceLastReport.elapsed > _timeBetweenReports) {
      _timeSinceLastReport.reset();
      _timeBetweenReports *= 2;
      if (_timeBetweenReports > _maxTimeBetweenReports)
        _timeBetweenReports = _maxTimeBetweenReports;
      for (MeasurementStation station in _metrics.keys) {
        log(
          '$station: '
          '${_metrics[station].values
               .map<String>(
                 (Measurement measurement) => '${metricToString(measurement.metric)}=$measurement'
               ).join(', ')
            } '
          '(${prettyDuration(now.difference(_metrics[station].values.reduce(_oldest).timestamp))} ago)'
        );
      }
    }
  }

  static Measurement _oldest(Measurement value, Measurement element) {
    assert(value != null);
    assert(element != null);
    if (value.timestamp.isBefore(element.timestamp))
      return value;
    return element;
  }
}

class MeasurementDataAdaptor extends ByteBuildingStreamDataAdaptor<MeasurementPacket> {
  MeasurementDataAdaptor({int tableId, @required int count, Stream<MeasurementPacket> stream}) : super(tableId: tableId, length: count * 8, stream: stream);

  @override
  void fill(MeasurementPacket packet) {
    for (final Measurement measurement in packet.parameters)
      pushDouble(measurement.value);
  }
}
