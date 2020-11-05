import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:home_automation_tools/all.dart';
import 'package:meta/meta.dart';

import 'lock.dart';

// listen with a secure socket for incoming data
// different channels have different data schema
// store recent data on SD card, rotate data to irusan
// listen with a secure socket for data requests

// logs additional information about networking
const bool verbose = false;

class Database {
  Database._(
    this._readSocket,
    this._writeSocket,
    this.databasePassword,
    this.localDirectory,
    this.remoteDirectory,
    this.onLog,
  ) {
    _readSocket.listen(_handleRead, onError: (Object error, StackTrace stack) { log('error on read socket: $error'); });
    _writeSocket.listen(_handleWrite, onError: (Object error, StackTrace stack) { log('error on write socket: $error'); });
    log('ready');
  }

  static Future<Database> connect({
    @required int readPort,
    @required int writePort,
    @required List<int> certificateChain,
    @required List<int> privateKey,
    @required int databasePassword,
    @required String localDirectory,
    @required String remoteDirectory,
    @required LogCallback onLog,
  }) async {
    assert(onLog != null);
    SecureServerSocket readSocket;
    SecureServerSocket writeSocket;
    SecurityContext certificate = SecurityContext()
      ..useCertificateChainBytes(certificateChain)
      ..usePrivateKeyBytes(privateKey);
    await Future.wait<void>(<Future<void>>[
      () async {
        readSocket = await SecureServerSocket.bind(
          InternetAddress.anyIPv4,
          readPort,
          certificate,
        );
      }(),
      () async {
        writeSocket = await SecureServerSocket.bind(
          InternetAddress.anyIPv4,
          writePort,
          certificate,
        );
      }(),
    ]);
    return Database._(readSocket, writeSocket, databasePassword, localDirectory, remoteDirectory, onLog);
  }

  final SecureServerSocket _readSocket;
  final SecureServerSocket _writeSocket;
  final int databasePassword;
  final String localDirectory;
  final String remoteDirectory;
  final LogCallback onLog;

  static const int kPasswordLength = 8; // bytes
  static const int kTableLength = 8; // bytes (Int64)
  static const int kCommandLength = 8; // bytes (Int64, 0=stream, 1=get range)
  static const int kDateLength = 8; // bytes (Uint64 milliseconds since epoch)

  Future<void> _handleWrite(SecureSocket socket) async {
    socket.done.catchError((Object error) { });
    final PacketBuffer buffer = PacketBuffer();
    String client = '${socket.remoteAddress.address}';
    try {
      String client = '${(await socket.remoteAddress.reverse()).host} (${socket.remoteAddress.address})';
      if (verbose)
        log('received connection on write socket from $client');
      await for (Uint8List packet in socket) {
        buffer.add(packet);
        if (buffer.available < kPasswordLength + kTableLength) {
          if (verbose)
            log('insufficient data on write socket from $client... (${buffer.available} bytes available, need ${kPasswordLength + kTableLength})');
          continue;
        }
        int password = buffer.readInt64();
        if (password != databasePassword)
          throw SocketException('invalid password on write request');
        int tableId = buffer.readInt64();
        Table table = getTable(tableId); // throws if id is invalid
        int recordSize = table.inputRecordSize;
        if (buffer.available < recordSize) {
          if (verbose)
            log('insufficient data on write socket from $client to write to ${table.name}... (${buffer.available} bytes available, need $recordSize)');
          buffer.rewind();
          continue;
        }
        Uint8List record = buffer.readUint8List(recordSize);
        if (verbose)
          log('received ${record.length} byte record from $client to write to ${table.name}');
        table.add(TableRecord.now(record));
        buffer.checkpoint();
      }
    } catch (error) {
      log('error: $error on write socket from $client');
    }
    await socket.close().catchError(() { }); // errors closing sockets don't really matter
  }

  void write(int tableId, Uint8List data) {
    Table table = getTable(tableId); // throws if id is invalid
    int recordSize = table.inputRecordSize;
    if (data.length < recordSize)
      throw ArgumentError('Table ${table.name} expects records of size $recordSize bytes but write() was called with ${data.length} bytes');
    if (verbose)
      log('received ${data.length} byte record locally to write to ${table.name}');
    table.add(TableRecord.now(data));
  }

  int _readConnectionCount = 0;

  Future<void> _handleRead(SecureSocket socket) async {
    _readConnectionCount += 1;
    int connectionId = _readConnectionCount;
    final PacketBuffer buffer = PacketBuffer();
    String client = '${socket.remoteAddress.address} (#$connectionId)';
    try {
      bool connected = true;
      socket.done.then((Object result) {
        log('connection with $client terminated');
      }, onError: (Object error) {
        log('connection with $client terminated ($error)');
      }).whenComplete(() {
        connected = false;
      });
      client = '${(await socket.remoteAddress.reverse()).host} (${socket.remoteAddress.address}, #$connectionId)';
      log('connection received on read socket from $client');
      await for (Uint8List packet in socket) {
        buffer.add(packet);
        if (buffer.available < kTableLength + kCommandLength) {
          buffer.rewind();
          continue;
        }
        int tableId = buffer.readInt64();
        Table table = getTable(tableId);
        int command = buffer.readInt64();
        switch (command) {
          case 0x00: // streaming
            log('received streaming request for table ${table.name} from $client');
            socket.setOption(SocketOption.tcpNoDelay, true);
            if (table.lastRecord != null)
              socket.add(table.lastRecord.encode());
            Completer<TableRecord> nextRecord = Completer<TableRecord>();
            StreamSubscription<TableRecord> subscription = table.stream.listen((TableRecord record) {
              nextRecord.complete(record);
              nextRecord = Completer<TableRecord>();
            });
            while (true) {
              TableRecord record = await nextRecord.future;
              if (connected) {
                log('sending $record to $client');
                socket.add(record.encode());
              } else {
                break;
              }
            }
            await subscription.cancel();
            break;
          case 0x01: // read range
            if (buffer.available < kDateLength * 2) {
              buffer.rewind();
              continue;
            }
            DateTime startDate = DateTime.fromMillisecondsSinceEpoch(buffer.readInt64(), isUtc: true);
            DateTime endDate = DateTime.fromMillisecondsSinceEpoch(buffer.readInt64(), isUtc: true);
            // read all records between two dates
            // write the number of bytes about to be dumped
            // dump all the bytes for records between the two dates
            throw UnimplementedError();
            break;
          default:
            log('received unknown command $command for table ${table.name} on read socket from $client');
        }
      }
    } catch (error, stack) {
      log('error: $error on read socket from $client\n$stack');
      await socket.close().catchError(() { }); // errors closing sockets really don't matter
    }
  }

  static const int dbSolarTable = 0x0000000000000001;
  static const int dbDishwasherTable = 0x0000000000000002;
  static const int dbHouseSensors = 0x0000000000000003;

  final Map<int, Table> _tables = <int, Table>{};

  Table getTable(int id) {
    if (!_tables.containsKey(id)) {
      switch (id) {
        case dbSolarTable:
          _tables[id] = Table('solar', 8, localDirectory, remoteDirectory, onLog); // wattage as a double
          break;
        case dbDishwasherTable:
          _tables[id] = Table('dishwasher', 28, localDirectory, remoteDirectory, onLog); // complicated structure:
          // 28 byte structure consisting of the following bytes and words. Bits are given with LSB first.
          // BYTE 0: user configuration
          //   delay - 2 bits (hours, 00=0h, 01=2h, 10=4h, 11=8h)
          //   cycle mode - 2 bits (00=autosense, 01=heavy, 10=normal, 11=light)
          //   steam - 1 bit
          //   rinse aid enabled - 1 bit
          //   wash temp - 2 bits (00=normal, 01=boost, 10=sanitize)
          // BYTE 1: user configuration, continued
          //   heated dry - 1 bit
          //   uiLocked - 1 bit
          //   mute - 1 bit
          //   sabbath mode - 1 bit
          //   demo - 1 bit
          //   leak detect enabled - 1 bit
          //   reserved - 2 bits
          // BYTE 2: current operating status
          //   operating mode - 4 bits (0..10: lowPower, powerUp, standBy, delayStart, pause, active, endOfCycle, downloadMode, sensorCheckMode, loadActivationMode, machineControlOnly)
          //   cycle state - 4 bits (0..9: none, preWash, sensing, mainWash, drying, sanitizing, turbidityCalibration, diverterCalibration, pause, rinsing)
          // BYTE 3: current operating status
          //   cycle mode - 3 bits (0..5: none, autosense, heavy, normal, light )
          //   reserved - 5 bits
          // BYTE 4: cycle step
          // BYTE 5: cycle substep
          // BYTES 6 and 7: duration, in minutes, big-endian
          // BYTE 8: steps executed
          // BYTE 9: steps estimated
          // BYTE 10: last error ID
          // BYTE 11: reserved
          // BYTE 12: minimum temperature
          // BYTE 13: maximum temperature
          // BYTE 14: final temperature
          // BYTE 15: reserved
          // BYTES 16 and 17: minimum turbidity, big-endian
          // BYTES 18 and 19: maximum turbidity, big-endian
          // BYTES 20 and 11: cycles started, big-endian
          // BYTES 22 and 23: cycles completed, big-endian
          // BYTES 24 and 25: door count, big-endian
          // BYTES 26 and 27: power-on count, big-endian
          break;
        case dbHouseSensors:
          _tables[id] = Table('house_sensors', 1, localDirectory, remoteDirectory, onLog);
          // BYTE 0:
          //  front door - 1 bit (LSB)
          //  garage door - 1 bit
          //  back door - 1 bit
          //  reserved - 4 bits
          //  no data - 1 bit (MSB) (all others bits will also be set when data is unavailable)
          break;
        default:
          throw UnsupportedError('no table with id 0x${id.toRadixString(16)}');
      }
    }
    return _tables[id];
  }

  @protected
  void log(String message) {
    onLog(message);
  }

  void dispose() {
    _writeSocket.close().catchError((Object error) { });
    _readSocket.close().catchError((Object error) { });
  }
}

class Table {
  Table(this.name, this.inputRecordSize, this.localDirectory, this.remoteDirectory, this.onLog) {
    _lock.run(_openFile);
  }

  final String name; // used in the filesystem
  
  final int inputRecordSize; // bytes per record, not counting timestamp or checksum
  int get fullRecordSize => 8 + inputRecordSize + 8; // timestamp + data + checksum

  final String localDirectory;
  final String remoteDirectory;

  final LogCallback onLog;

  String get localFilename => '$localDirectory/$name.db';
  String generateBackupFilename(DateTime timestamp) {
    return '$remoteDirectory/$name.${timestamp.millisecondsSinceEpoch}.db';
  }

  // rotate the database once the database is at least 4 weeks old and at least 10 MB.
  static const Duration kMinAge = Duration(days: 28);
  static const int kMinLength = 10 * 1024 * 1024; // 10MB

  RandomAccessFile _file;
  DateTime _fileTimestamp;

  TableRecord _lastRecord;
  TableRecord get lastRecord => _lastRecord;

  Lock _lock = Lock();

  final StreamController<TableRecord> _broadcastController = StreamController<TableRecord>.broadcast();
  Stream<TableRecord> get stream => _broadcastController.stream;

  // only valid to call while locked
  Future<void> _openFile() async {
    _file = await File(localFilename).open(mode: FileMode.append);
    int length = await _file.length();
    if (length >= fullRecordSize) {
      await _file.setPosition(0);
      Uint8List bytes = await _file.read(8);
      _fileTimestamp = DateTime.fromMillisecondsSinceEpoch(bytes.buffer.asByteData().getUint64(0), isUtc: true);
      // TODO(ianh): fill in _lastRecord
    } else {
      _fileTimestamp = null;
    }
    await _file.setPosition((length ~/ fullRecordSize) * fullRecordSize);
  }

  // only valid to call while locked
  Future<void> _rotateFile(DateTime nextTimestamp) async {
    if (_fileTimestamp == null)
      return; // file is empty
    if (nextTimestamp.difference(_fileTimestamp) < kMinAge)
      return; // file isn't old enough
    int length = await _file.length();
    if (length < kMinLength)
      return; // file isn't big enough
    await _file.close();
    final String remoteFileName = generateBackupFilename(_fileTimestamp);
    log('rotating $name database ($localFilename -> $remoteFileName)');
    await File(localFilename).rename(remoteFileName);
    await _openFile();
  }

  void add(TableRecord record) {
    assert(record.size == fullRecordSize);
    _lock.run(() async {
      await _rotateFile(record.timestamp);
      _fileTimestamp ??= record.timestamp;
      log('$name received $record');
      await _file.writeFrom(record.encode());
      _lastRecord = record;
      _broadcastController.add(record);
    });
  }

  Future<List<Uint8List>> read({
    @required DateTime start,
    @required DateTime end,
    @required Duration resolution,
  }) async {
    throw UnimplementedError();
    await _lock.run(() async {
      // ...
    });
    return null; // TODO(ianh) ...
  }

  @protected
  void log(String message) {
    onLog(message);
  }

  void dispose() {
    _lock.run(() async {
      await _file.close();
      _lock.dispose();
    });
  }
}
