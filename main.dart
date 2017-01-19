import 'dart:io';

import 'package:stack_trace/stack_trace.dart';
import 'package:dart-home-automation-tools/lib/all.dart';

import 'laundry.dart';
import 'solar.dart';
import 'house_sensors.dart';

const String houseSensorsId = '243c201de435';
const String laundryId = '00e04c02bd93';
const String solarDisplayId = '243c201ddaf1';
const String cloudBitTest1Id = '243c201dc805';
const String cloudBitTest2Id = '243c201dcdfd';
const String thermostatId = '00e04c0355d0';

void log(String module, String s) {
    String timestamp = new DateTime.now().toIso8601String().padRight(26, '0');
    print('$timestamp $module: $s');
}

void main() {
  Chain.capture(
    () async {
      log('system', 'house of rooves deamon initialising...');
      List<String> credentials = new File('credentials.cfg').readAsLinesSync();
      if (credentials.length < 5)
        throw new Exception('credentials file incomplete or otherwise corrupted');
      RemyMultiplexer remy = new RemyMultiplexer(
        'automatic-tools-2',
        credentials[2],
        onLog: (String message) { log('remy', message); },
      );
      LittleBitsCloud cloud = new LittleBitsCloud(
        authToken: credentials[0],
        onError: (dynamic error) {
          log('cloudbits', '$error');
        },
      );
      SunPowerMonitor solar = new SunPowerMonitor(
        customerId: credentials[1],
        onError: (dynamic error) {
          log('sunpower', '$error');
        },
      );
      await remy.ready;
      new LaundryRoomModel(
        cloud,
        remy,
        laundryId,
        onLog: (String message) { log('laundry', message); },
      );
      new HouseSensorsModel(
        cloud,
        remy,
        houseSensorsId,
        onLog: (String message) { log('house sensors', message); },
      );
      new SolarModel(
        cloud,
        solar,
        remy,
        solarDisplayId,
        onLog: (String message) { log('solar', message); },
      );

      // The next step is a TV multiplexer that exposes a useful subset of the TV API,
      // as well as a display abstraction so that multiple messages can be displayed at once.
      //
      // Think about how the dishwasher might be connected to this.

      log('system', 'house of rooves deamon online');
    },
    onError: (dynamic error, Chain stack) {
      log('system', '$error\n${stack.terse}');
    },
  );
}
