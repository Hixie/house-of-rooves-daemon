import 'dart:io';

class Credentials {
  Credentials(String filename) : this._lines = new File(filename).readAsLinesSync() {
    if (_lines.length < _requiredCount)
      throw new Exception('credentials file incomplete or otherwise corrupted');
  }
  final List<String> _lines;

  String get littleBitsToken => _lines[0];
  String get sunPowerCustomerId => _lines[1];
  String get remyPassword => _lines[2];
  String get tvHost => _lines[3];
  String get tvUsername => _lines[4];
  String get tvPassword => _lines[5];
  String get ttsHost => _lines[6];
  String get ttsPassword => _lines[7];
  String get airNowApiKey => _lines[8];

  int get _requiredCount => 9;
}
