import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:home_automation_tools/all.dart';

import 'common.dart';

abstract class Message {
  Message();

  MessageCenter _messageCenter;

  String get message;
  
  bool get announce => false;

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

  bool _active = true;
  Future<Null> _lastInLine = new Future<Null>.value(null);
  Future<Null> announce(String message, int level, { bool verbal: true, bool auditoryIcon: true, bool visual: true }) async {
    Completer<Null> completer = new Completer<Null>();
    Future<Null> previousInLine = _lastInLine;
    _lastInLine = completer.future;
    await previousInLine;
    if (!_active)
      return;
    StringMessage visualHandle;
    if (visual)
      visualHandle = showMessage(message);
    if (auditoryIcon)
      await tts.alarm(level);
    if (!_active)
      return;
    if (verbal)
      await tts.speak(message);
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
      tv.showMessage(line);
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
