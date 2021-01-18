import 'dart:async';

class Lock {
  Completer<void> _currentLock = Completer<void>()..complete();

  Future<void> run(Future<void> Function() body) async {
    Future<void> previousLock = _currentLock.future;
    Completer<void> ourLock = Completer<void>();
    _currentLock = ourLock;
    await previousLock;
    try {
      await body();
    } finally {
      ourLock.complete();
    }
  }

  Stream<T> stream<T>(Stream<T> Function() body) async* {
    Future<void> previousLock = _currentLock.future;
    Completer<void> ourLock = Completer<void>();
    _currentLock = ourLock;
    await previousLock;
    try {
      yield* body();
    } finally {
      ourLock.complete();
    }
  }

  void dispose() {
    _currentLock = null;
  }
}
