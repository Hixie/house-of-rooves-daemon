cd ~/dev/house-of-rooves-daemon/
pub get
while (true); do (dart --enable-asserts lib/main.dart 2>&1 | tee -a ~/dev/house-of-rooves-daemon/logs/log.current); done
