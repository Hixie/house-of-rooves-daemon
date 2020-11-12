import 'dart:async';
import 'dart:typed_data';

import 'package:home_automation_tools/all.dart';
import 'package:meta/meta.dart';

import '../common.dart';
import 'database.dart';

class DataIngestor extends Model {
  DataIngestor({ LogCallback onLog, this.database }) : super(onLog: onLog);

  final Database database;

  List<DataAdaptor> _adaptors = <DataAdaptor>[];

  void addSource(DataAdaptor adaptor) {
    _adaptors.add(adaptor);
    if (!privateMode)
      adaptor.start(database);
  }

  @override
  set privateMode(bool value) {
    bool previous = privateMode;
    super.privateMode = value;
    if (privateMode != previous) {
      if (privateMode) {
        log('disabling logging due to private mode');
        for (DataAdaptor adaptor in _adaptors)
          adaptor.end();
      } else {
        log('reenabling logging, private mode disabled');
        for (DataAdaptor adaptor in _adaptors)
          adaptor.start(database);
      }
    }
  }

  void dispose() {
    for (DataAdaptor adaptor in _adaptors)
      adaptor.end();
  }
}

abstract class DataAdaptor {
  DataAdaptor(this.tableId) : assert(tableId != null);

  final int tableId;
  Database _database;

  @mustCallSuper
  void start(Database database) {
    _database = database;    
  }

  void write(Uint8List data) {
    assert(data != null);
    _database.write(tableId, data);
  }

  @mustCallSuper
  void end() {
    _database = null;
  }
}

abstract class StreamDataAdaptor<T> extends DataAdaptor {
  StreamDataAdaptor(int tableId, this.stream) : assert(stream != null), super(tableId);

  final Stream<T> stream;

  StreamSubscription<T> _subscription;

  @override
  void start(Database database) {
    super.start(database);
    _subscription = stream.listen(_handleUpdate);
  }

  void _handleUpdate(T next) {
    write(adapt(next));
  }

  @override
  void end() {
    _subscription.cancel();
    super.end();
  }

  Uint8List adapt(T next);
}

class DoubleStreamDataAdaptor extends StreamDataAdaptor<double> {
  DoubleStreamDataAdaptor({int tableId, Stream<double> stream}) : super(tableId, stream);

  @override
  Uint8List adapt(double next) {
    if (next == null)
      return Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    final ByteData byteData = ByteData(8)..setFloat64(0, next);
    return byteData.buffer.asUint8List();
  }
}

class TemperatureStreamDataAdaptor extends StreamDataAdaptor<Temperature> {
  TemperatureStreamDataAdaptor({int tableId, Stream<Temperature> stream}) : super(tableId, stream);

  @override
  Uint8List adapt(Temperature next) {
    if (next == null)
      return Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    final ByteData byteData = ByteData(8)..setFloat64(0, next.celsius);
    return byteData.buffer.asUint8List();
  }
}

abstract class ByteBuildingStreamDataAdaptor<T> extends StreamDataAdaptor<T> {
  ByteBuildingStreamDataAdaptor({int tableId, this.length, Stream<T> stream}) : super(tableId, stream);

  final int length; // payload bytes

  ByteData _byteData;
  int _position;
  int _bit;

  @override
  Uint8List adapt(T next) {
    assert(_byteData == null);
    if (next == null)
      return Uint8List.fromList(List<int>.filled(length, 0xFF));
    _byteData = ByteData(length);
    _position = 0;
    _bit = 0;
    fill(next);
    if (_bit > 0)
      _position += 1;
    assert(_position == length);
    final Uint8List result = _byteData.buffer.asUint8List();
    _byteData = null;
    return result;
  }

  void pushBit(bool data) {
    int byte = _byteData.getUint8(_position);
    final int mask = 0x01 << _bit;
    if (data) {
      byte |= mask;
    } else {
      byte &= ~mask;
    }
    _byteData.setUint8(_position, byte);
    _bit += 1;
    if (_bit > 7) {
      _bit = 0;
      _position += 1;
    }
  }

  void pushByte(int data) {
    _byteData.setUint8(_position, data);
    _position += 1;
    _bit = 0;
  }

  void pushInteger(int data) {
    _byteData.setInt64(_position, data);
    _position += 8;
    _bit = 0;
  }

  void pushDouble(double data) {
    _byteData.setFloat64(_position, data);
    _position += 8;
    _bit = 0;
  }

  void fill(T next);
}
