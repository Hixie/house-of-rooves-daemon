import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:home_automation_tools/all.dart';

import 'common.dart';

abstract class Message {
  Message();

  MessageCenter _messageCenter;

  String get message;
  
  bool get requiresCleanup => false;

  @protected
  void started() { } // called when the message is added to the MessageCenter

  @protected
  void ended() { } // called when the message is removed by hide()

  @protected
  void update() {
    _messageCenter?._markNeedsUpdate();
  }

  void hide() {
    assert(_messageCenter != null);
    _messageCenter._remove(this);
  }
}

class StringMessage extends Message {
  StringMessage(this._message);

  @override
  String get message => _message;
  String _message;
  set message(String value) {
    if (_message == value)
      return;
    _message = value;
    update();
  }
}

class HudMessage extends Message {
  HudMessage(this._label, { this.timeout, this.reminder });

  final Duration timeout;
  final Duration reminder;

  Timer _timer;
  bool _hidden = false;

  bool get enabled => _enabled;
  bool _enabled = false;
  set enabled(bool value) {
    if (_enabled == value)
      return;
    _enabled = value;
    _hidden = false;
    if (value) {
      if (timeout != null)
        _timer = new Timer(timeout, _triggerTimeout);
    } else {
      _timer?.cancel();
      _timer = null;
    }
    update();
  }

  void enable() {
    enabled = true;
  }

  void disable() {
    enabled = false;
  }

  String get label => _label;
  String _label;
  set label(String value) {
    if (_label == value)
      return;
    _label = value;
    update();
  }

  void _triggerTimeout() {
    _hidden = true;
    update();
    if (reminder != null)
      _timer = new Timer(reminder, _triggerReminder);
  }

  void _triggerReminder() {
    _hidden = false;
    update();
    if (timeout != null)
      _timer = new Timer(timeout, _triggerTimeout);
  }

  @override
  String get message {
    if (!_enabled || _hidden)
      return null;
    return _label;
  }
}

class SpinnerMessage extends Message {
  SpinnerMessage();

  Timer _timer;
  int frame = 0;

  @override
  void started() {
    assert(_timer == null);
    _timer = new Timer.periodic(const Duration(milliseconds: 220), (Timer timer) {
      frame += 1;
      update();
    });
  }

  @override
  bool get requiresCleanup => true;

  @override
  String get message {
    const List<String> frames = const <String>[
//      '\\', '|', '/', '-', // doesn't work well since the font is proportional
//      '<', '/', '>', '\\', // better but still not enough
      '|IIII', 'I|III', 'II|II', 'III|I', 'IIII|', 'III|I', 'II|II', 'I|III', // works ok
//      ' o  ', '  o ', '   o', '  o ', ' o  ', 'o   ',
//      '>   ', ' >  ', '  > ', '   >', '   <', '  < ', ' <  ', '<   ',
    ];
    assert(_timer != null);
    return frames[frame % frames.length];
  }

  @override
  void hide() {
    assert(_timer != null);
    super.hide();
    _timer.cancel();
    _timer = null;
  }
}

class ProgressMessage extends Message {
  ProgressMessage({ this.min: 0.0, this.max: 1.0, double value: 0.0, this.showBar: true, this.showValue: true }) : _value = value;

  final double min;
  final double max;

  final bool showBar;
  final bool showValue;

  double get value => _value;
  double _value;
  set value(double newValue) {
    newValue = newValue.clamp(min, max);
    if (value == newValue)
      return;
    _value = newValue;
    update();
  }

  @override
  String get message {
    StringBuffer buffer = new StringBuffer();
    if (showBar) {
      buffer.write('[');
      int perTen = (10.0 * (value - min) / (max - min)).floor();
      if (perTen > 0)
        buffer.write('*' * perTen);
      if (perTen < 10)
        buffer.write(' ' * (10 - perTen));
      buffer.write(']');
    }
    if (showBar && showValue)
      buffer.write(' ');
    if (showValue) {
      double perCent = 100.0 * (value - min) / (max - min);
      buffer.write(perCent.toStringAsFixed(1));
      buffer.write('%');
    }
    return buffer.toString();
  }
}

class MessageCenter extends Model {
  MessageCenter(this.tv, this.tts, { LogCallback onLog }) : super(onLog: onLog);

  final Television tv;
  final TextToSpeechServer tts;

  Set<Message> _messages = new LinkedHashSet<Message>();

  void show(Message message) {
    message._messageCenter = this;
    message.started();
    _messages.add(message);
    _markNeedsUpdate();
  }

  StringMessage showMessage(String message) {
    StringMessage result = new StringMessage(message);
    show(result);
    return result;
  }

  HudMessage createHudMessage(String label, { bool on: false, Duration timeout, Duration reminder }) {
    HudMessage result = new HudMessage(label, timeout: timeout, reminder: reminder);
    if (on)
      result.enable();
    show(result);
    return result;
  }

  int _lastAuditoryIconLevel = 0;
  DateTime _lastAuditoryIconTimeStamp = new DateTime.now();

  bool _active = true;
  Future<Null> _lastInLine = new Future<Null>.value(null);
  Future<Null> announce(String message, int level, { bool verbal: true, bool auditoryIcon: true, bool visual: true, Duration duration: const Duration(seconds: 5) }) async {
    Completer<Null> completer = new Completer<Null>();
    Future<Null> previousInLine = _lastInLine;
    _lastInLine = completer.future;
    await previousInLine;
    if (!_active)
      return;
    StringMessage visualHandle;
    if (visual)
      visualHandle = showMessage(message);
    Future<Null> timeout = new Future<Null>.delayed(duration);
    if (auditoryIcon) {
      DateTime now = new DateTime.now();
      if (_lastAuditoryIconLevel < level || now.difference(_lastAuditoryIconTimeStamp) > const Duration(seconds: 20)) {
        switch (level) {
          case 1: await tts.audioIcon('low-low-high-low'); break;
          case 2: break;
          case 3:
          case 4:
          case 5:
          case 6:
          case 7:
          case 8: await tts.audioIcon('low-low-high-high'); break;
          case 9: await tts.audioIcon('low-low-high-low-strident');
        }
        _lastAuditoryIconTimeStamp = now;
        _lastAuditoryIconLevel = level;
      }
    }
    if (!_active)
      return;
    if (verbal)
      await tts.speak(message);
    await timeout;
    if (!_active)
      return;
    visualHandle?.hide();
    completer.complete();
  }

  bool _cleanupScheduled = false;

  void _remove(Message message) {
    _messages.remove(message);
    message.ended();
    message._messageCenter = null;
    if (message.requiresCleanup)
      _cleanupScheduled = true;
    _markNeedsUpdate();
    // TODO(ianh): Kill any ongoing text-to-speech from this message.
  }

  bool _updateScheduled = false;
  Timer _updater;
  void _markNeedsUpdate() {
    if (_updateScheduled)
      return;
    _updater?.cancel();
    _updater = new Timer(Duration.ZERO, _update);
    _updateScheduled = true;
  }

  void _update() {
    _updateScheduled = false;
    _updater = null;
    List<String> components = <String>[];
    for (Message message in _messages) {
      String component = message.message;
      if (component != null)
        components.add(component);
    }
    String line = components.join(' | ');
    if (line.isNotEmpty || _cleanupScheduled) {
      tv.showMessage(line).catchError((dynamic error, StackTrace stack) {
        assert(error is TelevisionException);
        // TV is probably turned off or something.
      });
      _updater = new Timer(const Duration(milliseconds: 2000), _update);
      _cleanupScheduled = false;
    }
  }

  void dispose() {
    _active = false;
    _updateScheduled = true;
    for (Message message in _messages.toList())
      _remove(message);
    assert(_messages.isEmpty);
    _updater?.cancel();
    _updater = null;
  }
}
