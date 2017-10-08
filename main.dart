import 'dart:async';
import 'dart:io';

import 'package:home_automation_tools/all.dart';

import 'house_sensors.dart';
import 'laundry.dart';
import 'shower_day.dart';
//import 'solar.dart';
import 'google_home.dart';

const String houseSensorsId = '243c201de435';
const String laundryId = '00e04c02bd93';
const String solarDisplayId = '243c201ddaf1';
const String cloudBitTestId = '243c201dc805';
const String showerDayId = '243c201dcdfd';
const String thermostatId = '00e04c0355d0';

void log(String module, String s) {
  String timestamp = new DateTime.now().toIso8601String().padRight(26, '0');
  print('$timestamp $module: $s');
}

Future<Null> main() async {
  try {
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
      onIdentify: (String deviceId) {
        if (deviceId == houseSensorsId)
          return 'house sensors';
        if (deviceId == laundryId)
          return 'laundry';
        if (deviceId == solarDisplayId)
          return 'solar display';
        if (deviceId == cloudBitTestId)
          return 'cloudbit test device';
        if (deviceId == showerDayId)
          return 'shower day display';
        if (deviceId == thermostatId)
          return 'thermostat';
        return deviceId;
      },
      onError: (dynamic error) {
        log('cloudbits', '$error');
      },
      onLog: (String deviceId, String message) {
        log('cloudbits', message);
      },
    );
    // SunPowerMonitor solar = new SunPowerMonitor(
    //   customerId: credentials[1],
    //   onError: (dynamic error) {
    //     log('sunpower', '$error');
    //   },
    // );
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
    // new SolarModel(
    //   cloud,
    //   solar,
    //   remy,
    //   solarDisplayId,
    //   onLog: (String message) { log('solar', message); },
    // );

    new ShowerDayModel(
      cloud,
      remy,
      showerDayId,
      onLog: (String message) { log('shower day', message); },
    );

    new GoogleHomeModel(
      remy,
      onLog: (String message) { log('home', message); },
    );

    // The next step is a TV multiplexer that exposes a useful subset of the TV API,
    // as well as a display abstraction so that multiple messages can be displayed at once.
    //
    // Think about how the dishwasher might be connected to this.

    log('system', 'house of rooves deamon online');
  } catch (error, stack) {
    log('system', '$error\n$stack');
  }
}
