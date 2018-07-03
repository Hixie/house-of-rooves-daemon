import 'dart:async';
import 'dart:io';

import 'package:home_automation_tools/all.dart';

import 'src/air_quality.dart';
import 'src/credentials.dart';
import 'src/google_home.dart';
import 'src/house_sensors.dart';
import 'src/laundry.dart';
import 'src/message_center.dart';
import 'src/remy_messages_model.dart';
import 'src/shower_day.dart';
//import 'src/solar.dart';
import 'src/television_model.dart';

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

    // SUPPORTING SERVICES

    Credentials credentials = new Credentials('credentials.cfg');
    RemyMultiplexer remy = new RemyMultiplexer(
      'house-of-rooves-daemon@pi.rooves.house',
      credentials.remyPassword,
      onLog: (String message) { log('remy', message); },
    );
    LittleBitsCloud cloud = new LittleBitsCloud(
      authToken: credentials.littleBitsToken,
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
    //   customerId: credentials.sunPowerCustomerId,
    //   onError: (dynamic error) {
    //     log('sunpower', '$error');
    //   },
    // );
    AirQualityMonitor airQuality = new AirQualityMonitor(
      apiKey: credentials.airNowApiKey,
      area: new GeoBox(-122.291453,37.306551, -121.946757,37.513806),
      onError: (String message) { log('airnowapi', message); },
    );
    TextToSpeechServer tts = new TextToSpeechServer(
      host: credentials.ttsHost,
      password: credentials.ttsPassword,
    );
    Television tv = new Television(
      host: (await InternetAddress.lookup(credentials.tvHost)).first,
      username: credentials.tvUsername,
      password: credentials.tvPassword,
    );
    MessageCenter messageCenter = new MessageCenter(tv, tts);
    await remy.ready;

    // TODO:
    //  - One Wire temperature sensor


    // MODELS

    new LaundryRoomModel(
      cloud,
      remy,
      tts,
      laundryId,
      onLog: (String message) { log('laundry', message); },
    );

    new HouseSensorsModel(
      cloud,
      remy,
      messageCenter,
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

    new AirQualityModel(
      airQuality,
      remy,
      onLog: (String message) { log('air quality', message); },
    );

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

    new TelevisionModel(
      tv,
      remy,
      messageCenter,
      onLog: (String message) { log('tv', message); },
    );

    new RemyMessagesModel(
      messageCenter,
      remy,
      onLog: (String message) { log('remy messages', message); },
    );

    log('system', 'house of rooves deamon online');

  } catch (error, stack) {
    log('system', '$error\n$stack');
  }
}
