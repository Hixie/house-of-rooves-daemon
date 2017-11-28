while (true); do (cd ~/dev/house-of-rooves-daemon/ && dart --checked lib/main.dart 2>&1 | tee -a ~/dev/house-of-rooves-daemon/logs/log.current); done
