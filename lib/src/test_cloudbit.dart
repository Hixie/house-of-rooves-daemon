import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

enum TestCloudbitMode {
  off,
  echo,
  serial,
  tvVolume,
}

class TestCloudbitModel extends Model {
  TestCloudbitModel(this._cloudbit, this._tv, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(_cloudbit.values.listen(_inputHandler));
    _subscriptions.add(_cloudbit.button.listen(_buttonHandler));
    _subscriptions.add(_tv.connected.listen(_tvConnectedHandler));
    log('model initialised');
  }

  final Localbit _cloudbit;
  final Television _tv;
  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  TestCloudbitMode _mode = TestCloudbitMode.off;

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  int _value;
  Stopwatch _timeSinceButton = new Stopwatch();
  bool _newInMode = true;

  void _inputHandler(int value) {
    if (value == null)
      return;
    _value = value;
    _update();
  }

  void _buttonHandler(bool value) {
    if (value == null)
      return;
    if (value == true) {
      _mode = TestCloudbitMode.values[(_mode.index + 1) % TestCloudbitMode.values.length];
      log('switching to $_mode');
      _timeSinceButton..reset()..stop();
      _newInMode = true;
    } else {
      _timeSinceButton..reset()..start();
    }
    _update();
  }

  bool _busy = false;
  Stopwatch _timeSinceColor = new Stopwatch();

  Future<Null> _update() async {
    if (_busy)
      return;
    _busy = true;
    try {
      if (_newInMode || _timeSinceColor.elapsedMilliseconds > 60000) {
        _cloudbit.setLedColor(LedColor.values[_mode.index]);
        _timeSinceColor..reset()..start();
      }
      switch (_mode) {
        case TestCloudbitMode.off:
          if (_newInMode)
            _cloudbit.setValue(0, silent: true);
          break;
        case TestCloudbitMode.echo:
          _cloudbit.setValue(_value, silent: true);
          break;
        case TestCloudbitMode.serial:
          log('Sending message...');
          _cloudbit.sendText('Hi');
          break;
        case TestCloudbitMode.tvVolume:
          if (_timeSinceButton.elapsedMilliseconds > 2000 && _value != null) {
            await _maybeSetVolume(((_value / 1024.0) * 40.0).round());
          } else {
            await _maybeGetVolume();
          }
          break;
      }
    } finally {
      _busy = false;
      _newInMode = false;
    }
  }

  bool _tvConnected = false;

  void _tvConnectedHandler(bool value) {
    _tvConnected = value;
  }

  int _currentVolume;
  Stopwatch _elapsedSinceReadVolume = new Stopwatch();

  Future<Null> _maybeGetVolume() async {
    assert(_busy);
    if (_newInMode || _elapsedSinceReadVolume.elapsedMilliseconds > 60000 ||
        (_tvConnected && _elapsedSinceReadVolume.elapsedMilliseconds > 5000)) {
      await _getVolume();
    }
  }

  Future<Null> _maybeSetVolume(int targetVolume) async {
    assert(_busy);
    if (_currentVolume != targetVolume) {
      try {
        log('setting TV volume to $targetVolume% (current volume is ${ _currentVolume != null ? "$_currentVolume%" : "unknown" })');
        await _tv.setVolume(targetVolume);
        _currentVolume = targetVolume;
      } catch (error) {
        log('error changing TV volume: $error');
      }
      await _getVolume();
    }
  }

  Future<Null> _getVolume() async {
    assert(_busy);
    _elapsedSinceReadVolume..reset()..start();
    int oldVolume = _currentVolume;
    try {
      _currentVolume = await _tv.volume;
    } catch (error) {
      log('error reading TV volume: $error');
    }
    if (oldVolume != _currentVolume)
      log('TV volume is ${ _currentVolume != null ? "$_currentVolume%" : "unknown" }');
    if (_currentVolume != null)
      _cloudbit.setValue(((_currentVolume / 40.0) * 1024.0).round().clamp(0, 1024), silent: true);
  }
}
