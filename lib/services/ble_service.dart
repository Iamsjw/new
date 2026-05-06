import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:permission_handler/permission_handler.dart';

class BleAdvertisementData {
  final String sessionId;
  final int rssi;
  final String deviceId;

  const BleAdvertisementData({
    required this.sessionId,
    required this.rssi,
    required this.deviceId,
  });
}

class BleService {
  static StreamSubscription<List<ScanResult>>? _scanSubscription;
  static Timer? _scanTimer;
  static final List<int> _rssiSamples = [];
  static bool _isAdvertising = false;

  // ---- Permissions ------------------------------------------------
  static Future<bool> requestPermissions() async {
    if (kIsWeb) return false;
    try {
      final permissions = [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ];
      if (!kIsWeb && !Platform.isIOS) {
        permissions.add(Permission.bluetoothAdvertise);
      }
      final results = await permissions.request();
      final allGranted = results.values.every(
        (s) => s == PermissionStatus.granted,
      );
      debugPrint('[BLE] Permissions: $results -> granted=$allGranted');
      return allGranted;
    } catch (e) {
      debugPrint('[BLE] Permission request failed: $e');
      return false;
    }
  }

  static Future<bool> hasPermissions() async {
    if (kIsWeb) return false;
    try {
      final permissions = [
        Permission.bluetoothScan.status,
        Permission.bluetoothConnect.status,
        Permission.locationWhenInUse.status,
      ];
      if (!kIsWeb && !Platform.isIOS) {
        permissions.add(Permission.bluetoothAdvertise.status);
      }
      final results = await Future.wait(permissions);
      return results.every((s) => s.isGranted);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isBluetoothOn() async {
    if (kIsWeb) return false;
    try {
      final state = await FlutterBluePlus.adapterState.first;
      return state == BluetoothAdapterState.on;
    } catch (_) {
      return false;
    }
  }

  // ---- Teacher: BLE Advertising ----------------------------------------
  static bool get isAdvertising => _isAdvertising;

  static Future<bool> isPeripheralSupported() async {
    if (kIsWeb) return false;
    try {
      return await FlutterBlePeripheral().isSupported;
    } catch (_) {
      return false;
    }
  }

  /// Start advertising using ONLY manufacturerData with a short session prefix.
  /// This is the most reliable method for cross-platform BLE advertising.
  static Future<bool> startAdvertising(String sessionId) async {
    if (kIsWeb) {
      debugPrint('[BLE] Web not supported');
      return false;
    }

    // Stop any ongoing scan that might conflict
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    // Step 1: Check Bluetooth
    debugPrint('[BLE] Checking Bluetooth state...');
    final isOn = await isBluetoothOn();
    debugPrint('[BLE] Bluetooth isOn=$isOn');
    if (!isOn) {
      debugPrint('[BLE] Cannot advertise: Bluetooth is off');
      return false;
    }

    // Step 2: Check peripheral support
    debugPrint('[BLE] Checking peripheral support...');
    try {
      final supported = await isPeripheralSupported();
      debugPrint('[BLE] Peripheral supported=$supported');
      if (!supported) {
        debugPrint('[BLE] Peripheral mode not supported on this device');
        return false;
      }
    } catch (e) {
      debugPrint('[BLE] Error checking peripheral support: $e');
      return false;
    }

    // Step 3: Build minimal advertising data
    try {
      final prefix = sessionId.length >= 8
          ? sessionId.substring(0, 8)
          : sessionId;
      debugPrint('[BLE] Advertising prefix: $prefix');
      final prefixBytes = utf8.encode(prefix);

      // Platform-aware: Android uses manufacturerData, iOS uses serviceData
      final advertiseData = Platform.isIOS
          ? AdvertiseData(
              serviceUuid: "19B10000-E8F2-537E-4F6C-D104768A1214",
              serviceData: Uint8List.fromList(prefixBytes),
              includeDeviceName: false,
            )
          : AdvertiseData(
              manufacturerId: 0x1234,
              manufacturerData: Uint8List.fromList(prefixBytes),
              includeDeviceName: false,
            );

      final settings = AdvertiseSettings(
        advertiseSet: true,
        advertiseMode: AdvertiseMode.advertiseModeLowLatency,
        connectable: false,
        timeout: 0,
      );

      debugPrint('[BLE] Calling FlutterBlePeripheral().start()...');
      await FlutterBlePeripheral().start(
        advertiseData: advertiseData,
        advertiseSettings: settings,
      );
      debugPrint('[BLE] FlutterBlePeripheral().start() returned');

      // Give it a moment, then verify
      await Future.delayed(const Duration(milliseconds: 800));
      final advertising = await FlutterBlePeripheral().isAdvertising;
      debugPrint('[BLE] isAdvertising after start: $advertising');

      if (!advertising) {
        debugPrint('[BLE] Warning: isAdvertising is false after start()');
        await Future.delayed(const Duration(seconds: 1));
        final retry = await FlutterBlePeripheral().isAdvertising;
        debugPrint('[BLE] Retry isAdvertising: $retry');
        if (!retry) {
          _isAdvertising = false;
          return false;
        }
      }

      _isAdvertising = true;
      debugPrint(
        '[BLE] Started advertising session: $sessionId (prefix: $prefix)',
      );
      return true;
    } catch (e, stackTrace) {
      debugPrint('[BLE] Failed to start advertising: $e');
      debugPrint('[BLE] Stack trace: $stackTrace');
      return false;
    }
  }

  static Future<void> stopAdvertising() async {
    try {
      await FlutterBlePeripheral().stop();
      debugPrint('[BLE] FlutterBlePeripheral().stop() succeeded');
    } catch (e) {
      debugPrint('[BLE] Error stopping advertising: $e');
    }
    _isAdvertising = false;
    debugPrint('[BLE] Stopped advertising');
  }

  // ---- Student: BLE Scanning -------------------------------------------
  static Future<BleAdvertisementData?> scanForSession({
    required String sessionId,
    required int timeoutSeconds,
    required int rssiThreshold,
    void Function(int rssi)? onRssiUpdate,
  }) async {
    if (kIsWeb) return null;

    final isOn = await isBluetoothOn();
    if (!isOn) return null;

    _rssiSamples.clear();
    final completer = Completer<BleAdvertisementData?>();

    try {
      await FlutterBluePlus.startScan(
        timeout: Duration(seconds: timeoutSeconds),
        androidScanMode: AndroidScanMode.lowLatency,
      );

      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final matched = _isTargetSession(result, sessionId);
          if (matched) {
            final rssi = result.rssi;
            _rssiSamples.add(rssi);
            onRssiUpdate?.call(rssi);

            if (_rssiSamples.length >= 3) {
              final avgRssi =
                  _rssiSamples.reduce((a, b) => a + b) ~/ _rssiSamples.length;
              if (!completer.isCompleted) {
                completer.complete(
                  BleAdvertisementData(
                    sessionId: sessionId,
                    rssi: avgRssi,
                    deviceId: result.device.remoteId.str,
                  ),
                );
              }
            }
          }
        }
      });

      _scanTimer = Timer(Duration(seconds: timeoutSeconds), () {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      });

      final result = await completer.future;
      await _stopScan();
      return result;
    } catch (e) {
      debugPrint('[BLE] Scan error: $e');
      await _stopScan();
      return null;
    }
  }

  /// Checks whether a scan result matches the target session.
  /// Matches by: (1) manufacturerData containing session prefix (primary),
  /// (2) serviceData, (3) device name containing the session prefix.
  static bool _isTargetSession(ScanResult result, String sessionId) {
    try {
      final prefix = sessionId.length >= 8
          ? sessionId.substring(0, 8)
          : sessionId;

      // Check manufacturerData (primary method with flutter_ble_peripheral)
      final mfgData = result.advertisementData.manufacturerData;
      for (final entry in mfgData.entries) {
        final decoded = utf8.decode(entry.value, allowMalformed: true);
        if (decoded.contains(prefix)) return true;
      }

      // Check serviceData
      final svcData = result.advertisementData.serviceData;
      for (final entry in svcData.entries) {
        final decoded = utf8.decode(entry.value, allowMalformed: true);
        if (decoded.contains(prefix)) return true;
      }

      // Fallback: match by device name
      final name = result.device.platformName;
      final advName = result.advertisementData.advName;
      final targetName = 'UX_$prefix';

      if (name.contains(targetName) ||
          advName.contains(targetName) ||
          name.contains('UpasthitiX') ||
          advName.contains('UpasthitiX')) {
        return true;
      }
    } catch (e) {
      debugPrint('[BLE] Error matching session: $e');
    }
    return false;
  }

  static Future<void> _stopScan() async {
    try {
      _scanTimer?.cancel();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  static Future<void> dispose() async {
    await _stopScan();
    await stopAdvertising();
  }

  // ---- RSSI signal quality -------------------------------------------
  static String rssiQualityLabel(int rssi) {
    if (rssi >= -50) return 'Excellent';
    if (rssi >= -60) return 'Good';
    if (rssi >= -70) return 'Fair';
    if (rssi >= -80) return 'Weak';
    return 'Very Weak';
  }

  static double rssiQualityPercent(int rssi) {
    return ((rssi + 100) / 70).clamp(0.0, 1.0);
  }
}
