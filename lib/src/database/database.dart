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
  static const int kDateLength = 8; // bytes (Int64 milliseconds since epoch)
  static const int kResolutionLength = 8; // bytes (Int64; milliseconds between records)

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

  // Commands:
  //
  //  [tableID][0x00000000] - streaming request
  //  [tableID][0x00000001][start][end][duration] - historical data read
  //
  // [tableID] is a 64bit signed integer.
  //
  // [start] and [end] are 64bit signed integers representing milliseconds since the epoch in UTC.
  // [duration] is a 64bit signed integer representing minimum milliseconds between events.

  Future<void> _handleRead(SecureSocket socket) async {
    _readConnectionCount += 1;
    int connectionId = _readConnectionCount;
    final PacketBuffer buffer = PacketBuffer();
    String client = '${socket.remoteAddress.address} (#$connectionId)';
    try {
      bool connected = true;
      socket.done.then((Object result) { 
        if (verbose)
         log('connection with $client terminated');
      }, onError: (Object error) {
        log('connection with $client terminated ($error)');
      }).whenComplete(() {
        connected = false;
      });
      client = '${(await socket.remoteAddress.reverse()).host} (${socket.remoteAddress.address}, #$connectionId)';
      if (verbose)
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
                if (verbose)
                  log('sending $record to $client');
                socket.add(record.encode());
              } else {
                break;
              }
            }
            await subscription.cancel();
            break;
          case 0x01: // read range
            if (buffer.available < kDateLength * 2 + kResolutionLength) {
              buffer.rewind();
              continue;
            }
            DateTime startDate = DateTime.fromMillisecondsSinceEpoch(buffer.readInt64(), isUtc: true); // inclusive
            DateTime endDate = DateTime.fromMillisecondsSinceEpoch(buffer.readInt64(), isUtc: true); // exclusive
            Duration resolution = Duration(milliseconds: buffer.readInt64());
            log('received archived records request for table ${table.name} from $client; start: $startDate, end: $endDate, resolution: $resolution');
            Stopwatch stopwatch = Stopwatch()..start();
            int count = 0;
            await for (Uint8List record in table.read(start: startDate, end: endDate, resolution: resolution)) {
              count += 1;
              socket.add(record);
            }
            //if (verbose)
              log('sent $count records to $client in ${stopwatch.elapsed.inMilliseconds}ms');
            await socket.close();
            break;
          default:
            log('received unknown command $command for table ${table.name} on read socket from $client');
        }
      }
    } on SocketException catch (error) {
      log('$client disconnected: $error');
    } catch (error, stack) {
      log('error: $error on read socket from $client\n$stack');
      await socket.close().catchError(() { }); // errors closing sockets really don't matter
    }
  }

  final Map<int, Table> _tables = <int, Table>{};

  Table getTable(int id) {
    // TODO(ianh): start using the length constants instead of hard-coding lengths below
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
          _tables[id] = Table('house-sensors', 1, localDirectory, remoteDirectory, onLog);
          // BYTE 0:
          //  front door - 1 bit (LSB)
          //  garage door - 1 bit
          //  back door - 1 bit
          //  reserved - 4 bits
          //  no data - 1 bit (MSB) (all others bits will also be set when data is unavailable)
          break;
        case dbThermostat:
          _tables[id] = Table('thermostat', 4, localDirectory, remoteDirectory, onLog);
          // BYTE 0: temperature, celsius, signed int8
          // BYTE 1: min point, celsius, signed int8
          // BYTE 2: max point, celsius, signed int8
          // BYTE 3:
          //   LSB bit 0: cooling allowed
          //       bit 1: heating allowed
          //       bit 2: cooling active
          //       bit 3: heating active
          //       bit 4: fan active
          //       bit 5: override enabled
          //       bit 6: recovery enabled
          //   MSB bit 7: reserved
          break;
        case dbFamilyRoomSensors:
          _tables[id] = Table('uradmonitor-family-room', 8*8, localDirectory, remoteDirectory, onLog);
          // 8 eight-byte doubles:
          //   Radiation (μSv/h)
          //   Temperature (℃)
          //   Humidity (RH)
          //   Pressure (Pa)
          //   VOC (Ω)
          //   CO₂ (ppm)
          //   Noise (dB)
          //   PM₂.₅ (µg/m³)
          break;
        case dbOutsideSensors:
          _tables[id] = Table('uradmonitor-outside', 10*8, localDirectory, remoteDirectory, onLog);
          // 10 eight-byte doubles:
          //   Temperature (℃)
          //   Humidity (RH)
          //   Pressure (Pa)
          //   VOC (Ω)
          //   CO₂ (ppm)
          //   Noise (dB)
          //   PM₁.₀ (µg/m³)
          //   PM₂.₅ (µg/m³)
          //   PM₁₀ (µg/m³)
          //   O₃ (ppb)
          break;
        case dbRackTemperature: // celsius as double
          _tables[id] = Table('temperature-rack', 8, localDirectory, remoteDirectory, onLog);
          break;
        case dbMasterBedroomTemperature: // celsius as double
          _tables[id] = Table('temperature-master-bedroom', 8, localDirectory, remoteDirectory, onLog);
          break;
        case dbFamilyRoomTemperature: // celsius as double
          _tables[id] = Table('temperature-family-room', 8, localDirectory, remoteDirectory, onLog);
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
      await _file.setPosition((length ~/ fullRecordSize - 1) * fullRecordSize);
      _lastRecord = TableRecord.fromRaw(await _file.read(fullRecordSize), requireNonNull: false);
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
    await File(localFilename).copy(remoteFileName);
    await File(localFilename).delete();
    await _openFile();
  }

  void add(TableRecord record) {
    assert(record.size == fullRecordSize);
    _lock.run(() async {
      await _rotateFile(record.timestamp);
      _fileTimestamp ??= record.timestamp;
      if (verbose)
        log('$name received $record');
      await _file.writeFrom(record.encode());
      _lastRecord = record;
      _broadcastController.add(record);
    });
  }

  Stream<Uint8List> read({
    @required DateTime start,
    @required DateTime end,
    @required Duration resolution,
  }) async* {
    Stopwatch overall = Stopwatch()..start();
    Stopwatch inner = Stopwatch()..start();
    Stopwatch a = Stopwatch();
    Stopwatch b = Stopwatch();
    Stopwatch c = Stopwatch();
    yield* _lock.stream<Uint8List>(() async* {
      inner.stop(); a.start();
      TableCursor cursor = await findRecord(start);
      inner.start(); a.stop();
      DateTime next = start;
      int count = 0;
      while (cursor != null && cursor.timestamp.isBefore(end)) {
        if (!cursor.timestamp.isBefore(next)) {
          inner.stop(); b.start();
          yield cursor.data;
          inner.start(); b.stop();
          count += 1;
          next = start.add(resolution * count);
          assert(next.isAfter(cursor.timestamp));
        }
        inner.stop(); c.start();
        bool needAsyncAdvance = cursor.advanceSync(next);
        if (needAsyncAdvance)
          await cursor.advanceAsync(next);
        inner.start(); c.stop();
      }
    });
    print('overall read took ${overall.elapsed.inMilliseconds}ms');
    print('a read took ${a.elapsed.inMilliseconds}ms');
    print('b read took ${b.elapsed.inMilliseconds}ms');
    print('c read took ${c.elapsed.inMilliseconds}ms');
    print('inner read took ${inner.elapsed.inMilliseconds}ms');
  }

  static final RegExp _databaseFilenamePattern = RegExp(r'/([^/.]+)\.([0-9]+)\.db$');

  Future<TableCursor> findRecord(DateTime timestamp) async {
    Stopwatch watch = Stopwatch()..start();
    Stopwatch dirtime = Stopwatch();
    try {
      if (_fileTimestamp != null && !_fileTimestamp.isAfter(timestamp))
        return _findRecordFromFile(timestamp, <File>[ File(localFilename) ].iterator);
      Directory archive = Directory(remoteDirectory);
      dirtime.start();
      List<DateTime> startTimestamps = (await archive.list().toList()) // XXX read this on startup, and cache it; reprepare on rotate; now this whole function can be sync (50ms)
        .where((FileSystemEntity entity) => entity is File)
        .map<Match>((FileSystemEntity file) => _databaseFilenamePattern.firstMatch(file.path))
        .where((Match match) => match != null && match.group(1) == name)
        .map<DateTime>((Match match) => DateTime.fromMillisecondsSinceEpoch(int.parse(match.group(2)), isUtc: true))
        .toList()
        ..sort();
      dirtime.stop();
      List<File> files = startTimestamps.map<File>((DateTime timestamp) => File(generateBackupFilename(timestamp))).toList();
      if (_fileTimestamp != null) {
        startTimestamps.add(_fileTimestamp);
        files.add(File(localFilename));
      }
      int index = binarySearch(min: 0, max: files.length, target: timestamp, getter: (int position) => startTimestamps[position]);
      if (startTimestamps[index].isAfter(timestamp) && index > 0)
        index -= 1;
      return _findRecordFromFile(timestamp, files.skip(index).iterator);
    } finally {
      print('findRecord $timestamp took ${watch.elapsed.inMilliseconds}ms; dirtime = ${dirtime.elapsed.inMilliseconds}ms');
    }
  }

  Future<TableCursor> _findRecordFromFile(DateTime timestamp, Iterator<File> nextFiles) async {
    if (!nextFiles.moveNext())
      throw StateError('_findRecordFromFile expected nextFiles to have at least one file');
    Stopwatch watch = Stopwatch()..start();
    Uint8List bytes = await nextFiles.current.readAsBytes();
    print('read took ${watch.elapsed.inMilliseconds}ms');
    ByteData view = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
    int position = binarySearch<DateTime>(
      min: 0,
      max: view.lengthInBytes ~/ fullRecordSize,
      target: timestamp,
      getter: (int position) {
        return DateTime.fromMillisecondsSinceEpoch(view.getUint64(position * fullRecordSize), isUtc: true);
      },
    );
    return TableCursor.start(this, view, position * fullRecordSize, nextFiles, onLog);
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

class TableCursor {
  TableCursor._(
    this.recordSize,
    this._file,
    this._position,
    this._nextFiles,
    this.onLog,
  ) : assert(_file.lengthInBytes > 0),
      assert(_file.lengthInBytes % recordSize == 0),
      _lastTimestamp = _prepareListTimestamp(_file, recordSize) {
    _readNextRecord();
  }

  static TableCursor start(Table table, ByteData bytes, int position, Iterator<File> nextFiles, LogCallback onLog) {
    return TableCursor._(table.fullRecordSize, bytes, position, nextFiles, onLog);
  }

  final int recordSize;
  final ByteData _file;
  final DateTime _lastTimestamp;
  int _position; // in bytes of _file
  final Iterator<File> _nextFiles;

  final LogCallback onLog;

  // timestamp of current record
  DateTime get timestamp => _timestamp;
  DateTime _timestamp;

  // bytes of current record including timestamp and checksum
  Uint8List get data => _data;
  Uint8List _data;

  static DateTime _prepareListTimestamp(ByteData file, int recordSize) {
    assert(file.lengthInBytes > 0);
    assert(file.lengthInBytes % recordSize == 0);
    return DateTime.fromMillisecondsSinceEpoch(file.getUint64(file.lengthInBytes - recordSize), isUtc: true);    
  }

  // Return a TableCursor for the next record; this operation is
  // destructive (don't use this object again after calling this,
  // unless it is the one returned).
  // 
  // If `next` is provided, it might skip records that are before
  // `next`.
  //
  // Returns null when there's no more records to read.
  //
  // Only call this if [advanceSync] returned true.
  Future<TableCursor> advanceAsync([DateTime next]) async {
    assert(timestamp == null || next == null || next.isAfter(timestamp));
    assert(_position >= _file.lengthInBytes || (next != null && next.isAfter(_lastTimestamp)));
    if (_nextFiles.moveNext()) {
      Stopwatch watch = Stopwatch()..start();
      Uint8List bytes = await _nextFiles.current.readAsBytes();
      log('read next file in ${watch.elapsed.inMilliseconds}ms');
      assert(bytes.length > 0);
      ByteData view = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
      return TableCursor._(recordSize, view, 0, _nextFiles, onLog);
    }
    return null;
  }

  // Advances this TableCursor if possible.
  //
  // Returns true if you need to call [advanceAsync] instead.
  bool advanceSync([DateTime next]) {
    assert(timestamp == null || next == null || next.isAfter(timestamp));
    if (_position >= _file.lengthInBytes || (next != null && next.isAfter(_lastTimestamp)))
      return true;
    _readRecord(next);
    return false;
  }

  void _readRecord(DateTime next) {
    if (next != null) {
      assert(!next.isAfter(_lastTimestamp));
      _position = recordSize * binarySearch<DateTime>(
        min: _position ~/ recordSize,
        max: _file.lengthInBytes ~/ recordSize,
        target: next,
        getter: (int position) {
          return DateTime.fromMillisecondsSinceEpoch(_file.getUint64(_file.offsetInBytes + position * recordSize), isUtc: true);
        },
      );
    }
    return _readNextRecord();
  }

  void _readNextRecord() {
    _data = _file.buffer.asUint8List(_file.offsetInBytes + _position, recordSize);
    _timestamp = DateTime.fromMillisecondsSinceEpoch(_file.getUint64(_position), isUtc: true);
    _position += recordSize;
  }

  @protected
  void log(String message) {
    onLog(message);
  }
}

typedef BinarySearchGetter<ValueType> = ValueType Function(int position);

int binarySearch<ValueType extends Comparable<ValueType>>({
  @required int min,
  @required int max,
  @required ValueType target,
  @required BinarySearchGetter<ValueType> getter,
}) {
  assert(max > min);
  int index;
  while (true) {
    index = min + (max - min) ~/ 2.0;
    ValueType value = getter(index);
    int comparison = value.compareTo(target);
    if (comparison == 0)
      return index;
    if (comparison < 0) {
      min = index + 1;
      if (max < min)
        return index + 1;
    } else {
      assert(comparison > 0);
      max = index - 1;
      if (max < min)
        return index;
    }
  }
}
