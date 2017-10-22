import 'dart:async';
import 'dart:collection';

import 'package:home_automation_tools/all.dart';

import 'common.dart';

class GoogleHomeModel extends Model {
  GoogleHomeModel(this.remy, { LogCallback onLog }) : super(onLog: onLog) {
    _subscriptions.add(remy.getStreamForNotification('medication-taken').listen(_handleRemyMedicationTakenState));
    _subscriptions.add(remy.getStreamForNotification('want-medication-morning').listen(_handleRemyWantMedicationMorning));
    _subscriptions.add(remy.getStreamForNotification('want-medication-afternoon').listen(_handleRemyWantMedicationAfternoon));
    _subscriptions.add(remy.getStreamForNotification('want-medication-evening').listen(_handleRemyWantMedicationEvening));
    log('model initialised');
  }

  final RemyMultiplexer remy;

  Set<StreamSubscription<dynamic>> _subscriptions = new HashSet<StreamSubscription<dynamic>>();

  void dispose() {
    for (StreamSubscription<bool> subscription in _subscriptions)
      subscription.cancel();
  }

  bool _morning = false;

  void _handleRemyWantMedicationMorning(bool state) {
    log('received remy status change - ${state == null ? 'unknown' : state ? 'morning medication needed' : 'no need for morning medication'}');
    _morning = state;
    _check();
  }

  bool _afternoon = false;

  void _handleRemyWantMedicationAfternoon(bool state) {
    log('received remy status change - ${state == null ? 'unknown' : state ? 'afternoon medication needed' : 'no need for afternoon medication'}');
    _afternoon = state;
    _check();
  }

  bool _evening = false;

  void _handleRemyWantMedicationEvening(bool state) {
    log('received remy status change - ${state == null ? 'unknown' : state ? 'evening medication needed' : 'no need for evening medication'}');
    _evening = state;
    _check();
  }

  bool _pending;

  void _handleRemyMedicationTakenState(bool state) {
    log('received remy status change - ${state == null ? 'unknown' : state ? 'medication taken notification pending' : 'no pending notification'}');
    _pending = state;
    _check();
  }

  void _check() {
    if ((_pending == true) && (_morning != null) && (_afternoon != null) && (_evening != null)) {
      remy.pushButtonById('tookMedicationAcknowledged');
      if (_morning) {
        DateTime now = new DateTime.now();
        if (now.hour < 14) {
          remy.pushButtonById('tookMedicationMorning');
        } else {
          remy.pushButtonById('tookMedicationMorningLate');
        }
      } else if (_afternoon) {
        remy.pushButtonById('tookMedicationAfternoon');
      } else if (_evening) {
        remy.pushButtonById('tookMedicationEvening');
      } else {
        log('not clear what medication we are talking about here');
      }
    }
  }
}
