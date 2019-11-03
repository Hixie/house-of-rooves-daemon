import 'dart:async';
import 'dart:io';

import 'package:home_automation_tools/all.dart';

import 'src/common.dart';
import 'src/credentials.dart';
import 'src/google_home.dart';
import 'src/house_sensors.dart';
import 'src/laundry.dart';
import 'src/message_center.dart';
import 'src/outside_air_quality.dart';
import 'src/remy_messages_model.dart';
import 'src/shower_day.dart';
import 'src/solar.dart';
import 'src/television_model.dart';
import 'src/thermostat.dart';
// import 'src/test_cloudbit.dart';

const String houseSensorsId = '243c201de435';
const String laundryId = '00e04c02bd93';
const String solarDisplayId = '243c201ddaf1';
const String cloudBitTestId = '243c201dc805'; // damaged :-(
const String showerDayId = '00e04c0355d0'; // was '243c201dcdfd', but that is damaged :-(
//const String testCloudbitId = '000000000000'; // non-existent

const String rackThermometerId = '0000074f7305';
const String masterBedroomThermometerId = '0115722937ff';
const String familyRoomThermometerId = '0000076b2ff7';

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
    // LittleBitsCloud cloud = new LittleBitsCloud(
    //   authToken: credentials.littleBitsToken,
    //   onIdentify: (String deviceId) {
    //     if (deviceId == houseSensorsId)
    //       return 'house sensors';
    //     if (deviceId == laundryId)
    //       return 'laundry';
    //     if (deviceId == solarDisplayId)
    //       return 'solar display';
    //     if (deviceId == cloudBitTestId)
    //       return 'cloudbit test device';
    //     if (deviceId == showerDayId)
    //       return 'shower day display';
    //     if (deviceId == testCloudbitId)
    //       return 'test';
    //     return deviceId;
    //   },
    //   onError: (dynamic error) {
    //     log('cloudbits', '$error');
    //   },
    //   onLog: (String deviceId, String message) {
    //     log('cloudbits', message);
    //   },
    // );
    LittleBitsLocalServer cloudbits = new LittleBitsLocalServer(
      onIdentify: (String deviceId) {
        if (deviceId == houseSensorsId)
          return const LocalCloudBitDeviceDescription('house sensors', 'cloudbit-housesensors.rooves.house');
        if (deviceId == laundryId)
          return const LocalCloudBitDeviceDescription('laundry', 'cloudbit-laundry.rooves.house');
        if (deviceId == solarDisplayId)
          return const LocalCloudBitDeviceDescription('solar display', 'cloudbit-solar.rooves.house');
        if (deviceId == cloudBitTestId)
          return const LocalCloudBitDeviceDescription('cloudbit test device', 'cloudbit-test1.rooves.house');
        if (deviceId == showerDayId)
          return const LocalCloudBitDeviceDescription('shower day display', 'cloudbit-shower.rooves.house');
        // if (deviceId == testCloudbitId)
        //   return const LocalCloudBitDeviceDescription('test', 'cloudbit-test.rooves.house');
        throw new Exception('Unknown cloudbit device ID: $deviceId');
      },
      onLog: (String deviceId, String message) {
        log('cloudbits', message);
      },
    );
    SunPowerMonitor solar = new SunPowerMonitor(
      customerUsername: credentials.sunPowerCustomerUsername,
      customerPassword: credentials.sunPowerCustomerPassword,
      onLog: (String message) { log('sunpower', message); },
    );
    AirNowAirQualityMonitor airNow = new AirNowAirQualityMonitor(
      apiKey: credentials.airNowApiKey,
      area: new GeoBox(-122.291453,37.306551, -121.946757,37.513806),
      onLog: (String message) { log('airnowapi', message); },
    );
    TextToSpeechServer tts = new TextToSpeechServer(
      host: credentials.ttsHost,
      password: credentials.ttsPassword,
      onLog: (String message) { log('tts', message); },
    );
    Television tv = new Television(
      host: (await InternetAddress.lookup(credentials.tvHost)).first,
      username: credentials.tvUsername,
      password: credentials.tvPassword,
    );
    MessageCenter messageCenter = new MessageCenter(
      tv,
      tts,
      onLog: (String message) { log('message center', message); },
    );
    Thermostat thermostat = new Thermostat(
      host: (await InternetAddress.lookup(credentials.thermostatHost)).first,
      username: credentials.thermostatUsername,
      password: credentials.thermostatPassword,
      onLog: (String message) { log('thermostat', message); },
      onError: (dynamic error) { log('thermostat', error.toString()); },
    );
    OneWireTemperature rackTemperature = new OneWireTemperature(
      id: rackThermometerId,
      station: new MeasurementStation(siteName: 'rack thermometer'),
      onLog: (String message) { log('1w-temp', '(rack) $message'); },
      onError: (dynamic error) { log('1w-temp', '(rack) $error'); },
    );
    OneWireTemperature masterBedroomTemperature = new OneWireTemperature(
      id: masterBedroomThermometerId,
      station: new MeasurementStation(siteName: 'master bedroom thermometer'),
      onLog: (String message) { log('1w-temp', '(master bedroom) $message'); },
      onError: (dynamic error) { log('1w-temp', '(master bedroom) $error'); },
    );
    OneWireTemperature familyRoomTemperature = new OneWireTemperature(
      id: familyRoomThermometerId,
      station: new MeasurementStation(siteName: 'family room thermometer'),
      onLog: (String message) { log('1w-temp', '(family room) $message'); },
      onError: (dynamic error) { log('1w-temp', '(family room) $error'); },
    );
    URadMonitor familyRoomURadMonitor = new URadMonitor(
      host: 'uradmonitor-family-room.rooves.house',
      station: new MeasurementStation(siteName: 'family room uRADMonitor'),
      onLog: (String message) { log('uradmonitor', '(family room) $message'); },
    );
    await remy.ready;

    // rackTemperature.temperature.listen((Temperature temperature) {
    //   if (temperature != null)
    //     log('1w-temp', '(rack) ${temperature.toStringAsCelsius()}');
    // });
    // masterBedroomTemperature.temperature.listen((Temperature temperature) {
    //   if (temperature != null)
    //     log('1w-temp', '(master bedroom) ${temperature.toStringAsCelsius()}');
    // });
    // familyRoomTemperature.temperature.listen((Temperature temperature) {
    //   if (temperature != null)
    //     log('1w-temp', '(family room) ${temperature.toStringAsCelsius()}');
    // });
    // familyRoomURadMonitor.dataStream.listen((MeasurementPacket measurements) {
    //   if (measurements != null)
    //     log('uradmonitor', '(family room) $measurements');
    // });
    // thermostat.temperature.listen((Temperature temperature) {
    //   if (temperature != null)
    //     log('thermostat', '$temperature');
    // });
    // thermostat.status.listen((ThermostatStatus status) {
    //   switch (status) {
    //     case ThermostatStatus.heating: log('thermostat', 'heating...'); break;
    //     case ThermostatStatus.cooling: log('thermostat', 'cooling...'); break;
    //     case ThermostatStatus.fan: log('thermostat', 'fan enabled'); break;
    //     case ThermostatStatus.idle: log('thermostat', 'idle'); break;
    //   }
    // });

    // MODELS

    HouseSensorsModel houseSensors = new HouseSensorsModel(
      await cloudbits.getDevice(houseSensorsId),
      remy,
      messageCenter,
      tts,
      onLog: (String message) { log('house sensors', message); },
    );

    List<Model> models = <Model>[
      new LaundryRoomModel(
        await cloudbits.getDevice(laundryId),
        remy,
        tts,
        onLog: (String message) { log('laundry', message); },
      ),
      new SolarModel(
        await cloudbits.getDevice(solarDisplayId),
        solar,
        remy,
        messageCenter,
        onLog: (String message) { log('solar', message); },
      ),
      new OutsideAirQualityModel(
        airNow,
        remy,
        onLog: (String message) { log('outside air quality', message); },
      ),
      houseSensors,
      new ShowerDayModel(
        await cloudbits.getDevice(showerDayId),
        remy,
        onLog: (String message) { log('shower day', message); },
      ),
      new GoogleHomeModel(
        remy,
        onLog: (String message) { log('home', message); },
      ),
      new TelevisionModel(
        tv,
        remy,
        messageCenter,
        onLog: (String message) { log('tv', message); },
      ),
      new RemyMessagesModel(
        messageCenter,
        remy,
        onLog: (String message) { log('remy messages', message); },
      ),
      new ThermostatModel(
        thermostat,
        remy,
        houseSensors,
        outdoorAirQuality: airNow.dataStream,
        indoorAirQuality: familyRoomURadMonitor.dataStream,
        upstairsTemperature: masterBedroomTemperature.temperature,
        downstairsTemperature: familyRoomTemperature.temperature,
        rackTemperature: rackTemperature.temperature,
        onLog: (String message) { log('thermostat model', message); },
      ),
      // new TestCloudbitModel(
      //   await cloudbits.getDevice(testCloudbitId),
      //   tv,
      //   onLog: (String message) { log('test cloudbit', message); },
      // ),
    ];

    remy.getStreamForNotification('private-mode').listen((bool state) {
      for (Model model in models)
        model.privateMode = state;
    });

    log('system', 'house of rooves deamon online');

  } catch (error, stack) {
    log('system', '$error\n$stack');
  }
}
