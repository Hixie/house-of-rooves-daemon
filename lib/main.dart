import 'dart:async';
import 'dart:io';

import 'package:home_automation_tools/all.dart';

import 'src/air_quality.dart';
import 'src/common.dart';
import 'src/credentials.dart';
import 'src/database/database.dart';
import 'src/database/adaptors.dart';
import 'src/google_home.dart';
import 'src/house_sensors.dart';
import 'src/laundry.dart';
import 'src/leak_monitor.dart';
import 'src/message_center.dart';
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

const int databaseWritePort = 7420;
const int databaseReadPort = 7421;

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
      onError: (dynamic error) async { log('thermostat', error.toString()); },
    );
    OneWireTemperature rackTemperature = new OneWireTemperature(
      id: rackThermometerId,
      station: new MeasurementStation(siteName: 'rack thermometer'),
      onLog: (String message) { log('1w-temp', '(rack) $message'); },
      onError: (dynamic error) async { log('1w-temp', '(rack) $error'); },
    );
    OneWireTemperature masterBedroomTemperature = new OneWireTemperature(
      id: masterBedroomThermometerId,
      station: new MeasurementStation(siteName: 'master bedroom thermometer'),
      onLog: (String message) { log('1w-temp', '(master bedroom) $message'); },
      onError: (dynamic error) async { log('1w-temp', '(master bedroom) $error'); },
    );
    OneWireTemperature familyRoomTemperature = new OneWireTemperature(
      id: familyRoomThermometerId,
      station: new MeasurementStation(siteName: 'family room thermometer'),
      onLog: (String message) { log('1w-temp', '(family room) $message'); },
      onError: (dynamic error) async { log('1w-temp', '(family room) $error'); },
    );
    URadMonitor familyRoomURadMonitor = new URadMonitor(
      host: 'uradmonitor-family-room.rooves.house',
      station: new MeasurementStation(siteName: 'family room uRADMonitor'),
      onLog: (String message) { log('uradmonitor', '(family room) $message'); },
    );
    URadMonitor outsideURadMonitor = new URadMonitor(
      host: 'uradmonitor-outside.rooves.house',
      station: new MeasurementStation(siteName: 'outside uRADMonitor', outside: true),
      onLog: (String message) { log('uradmonitor', '(outside) $message'); },
    );
    ProcessMonitor leakSensorKitchenSinkMonitor = ProcessMonitor(
      executable: '/home/ianh/dev/leak-sensor/leak-sensor-monitor',
      onLog: (String message) { log('leak sensor', '(kitchen sink) $message'); },
      onError: (dynamic error) async { log('leak sensor', '(kitchen sink) $error'); },
    );
    await remy.ready;

    Database database = await Database.connect(
      readPort: databaseReadPort,
      writePort: databaseWritePort,
      certificateChain: await File(credentials.certificatePath).readAsBytes(),
      privateKey: await File(credentials.privateKeyPath).readAsBytes(),
      databasePassword: credentials.databasePassword,
      localDirectory: credentials.localDatabaseDirectory,
      remoteDirectory: credentials.remoteDatabaseDirectory,
      onLog: (String message) { log('database', message); },
    );
    

    // MODELS

    HouseSensorsModel houseSensors = new HouseSensorsModel( // (added to models list by reference below)
      await cloudbits.getDevice(houseSensorsId),
      remy,
      messageCenter,
      tts,
      onLog: (String message) { log('house sensors', message); },
    );

    DataIngestor ingestor = DataIngestor( // (added to models list by reference below)
      database: database,
      onLog: (String message) { log('data ingestor', message); },
    );
    ingestor.addSource(HouseSensorsDataAdaptor(
      tableId: dbHouseSensors,
      model: houseSensors,
    ));
    ingestor.addSource(DoubleStreamDataAdaptor(
      tableId: dbSolarTable,
      stream: solar.power,
    ));
    ingestor.addSource(ThermostatDataAdaptor(
      tableId: dbThermostat,
      stream: thermostat.report,
    ));
    ingestor.addSource(TemperatureStreamDataAdaptor(
      tableId: dbRackTemperature,
      stream: rackTemperature.temperature,
    ));
    ingestor.addSource(TemperatureStreamDataAdaptor(
      tableId: dbMasterBedroomTemperature,
      stream: masterBedroomTemperature.temperature,
    ));
    ingestor.addSource(TemperatureStreamDataAdaptor(
      tableId: dbFamilyRoomTemperature,
      stream: familyRoomTemperature.temperature,
    ));
    ingestor.addSource(MeasurementDataAdaptor(
      tableId: dbFamilyRoomSensors,
      count: 8,
      stream: familyRoomURadMonitor.dataStream,
    ));
    ingestor.addSource(MeasurementDataAdaptor(
      tableId: dbOutsideSensors,
      count: 10,
      stream: outsideURadMonitor.dataStream,
    ));

    List<Model> models = <Model>[
      ingestor,
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
      new AirQualityModel(
        // TODO(ianh): convert the one-wire and thermostat sources to streams of MeasurementPackets and add them here
        <Stream<MeasurementPacket>>[ airNow.dataStream, familyRoomURadMonitor.dataStream, outsideURadMonitor.dataStream ],
        remy,
        onLog: (String message) { log('air quality', message); },
      ),
      new LeakMonitorModel(
        leakSensorKitchenSinkMonitor,
        remy,
        'KitchenSink',
        onLog: (String message) { log('leak sensor', '(kitchen sink) $message'); },
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
