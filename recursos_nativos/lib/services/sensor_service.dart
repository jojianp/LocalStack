import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

class SensorService {
  static final SensorService instance = SensorService._init();
  SensorService._init();

  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  Function()? _onShake;

  static const double _shakeThreshold = 15.0;
  static const Duration _shakeCooldown = Duration(milliseconds: 500);

  DateTime? _lastShakeTime;
  bool _isActive = false;

  bool get isActive => _isActive;

  bool get _isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || kIsWeb;

  void startShakeDetection(Function() onShake) {
    if (!_isSupportedPlatform) {
      debugPrint('Sensores não suportados nesta plataforma (${Platform.operatingSystem}).');
      return;
    }

    if (_isActive) {
      debugPrint('Detecção de shake já ativa.');
      return;
    }

    _onShake = onShake;
    _isActive = true;

    _accelerometerSubscription = accelerometerEventStream().listen(
      (AccelerometerEvent event) {
        _detectShake(event);
      },
      onError: (error) {
        debugPrint('Erro no acelerômetro: $error');
      },
    );

    debugPrint('Detecção de shake iniciada');
  }

  void _detectShake(AccelerometerEvent event) {
    final now = DateTime.now();

    if (_lastShakeTime != null &&
        now.difference(_lastShakeTime!) < _shakeCooldown) {
      return;
    }

    final double magnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    if (magnitude > _shakeThreshold) {
      debugPrint('Shake! Magnitude: ${magnitude.toStringAsFixed(2)}');
      _lastShakeTime = now;
      _vibrateDevice();
      _onShake?.call();
    }
  }

  Future<void> _vibrateDevice() async {
    try {
      if (!_isSupportedPlatform) return;

      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        await Vibration.vibrate(duration: 100);
      }
    } catch (e) {
      debugPrint('Vibração não suportada: $e');
    }
  }

  void stop() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _onShake = null;
    _isActive = false;
    debugPrint('⏹Detecção de shake parada');
  }
}
