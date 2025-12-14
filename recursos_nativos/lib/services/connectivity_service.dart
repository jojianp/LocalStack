import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService {
  static final ConnectivityService instance = ConnectivityService._init();
  ConnectivityService._init() {
    _init();
  }

  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(false);
  StreamSubscription<ConnectivityResult>? _sub;

  void _init() {
    _sub = Connectivity().onConnectivityChanged.listen((result) {
      final online = result != ConnectivityResult.none;
      isOnline.value = online;
    });

    Connectivity().checkConnectivity().then((result) {
      isOnline.value = result != ConnectivityResult.none;
    });
  }

  void dispose() {
    _sub?.cancel();
  }
}
