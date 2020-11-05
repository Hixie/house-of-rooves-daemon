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

class StreamDoubleDataAdaptor extends StreamDataAdaptor<double> {
  StreamDoubleDataAdaptor({int tableId, Stream<double> stream}) : super(tableId, stream);

  @override
  Uint8List adapt(double next) {
    if (next == null)
      return Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
    final ByteData byteData = ByteData(8)..setFloat64(0, next);
    return byteData.buffer.asUint8List();
  }
}
