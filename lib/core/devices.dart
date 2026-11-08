import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'sdk.dart';

/// A device or simulator `flutter devices` can see.
class Device {
  final String id;
  final String name;
  final String platform;
  final bool emulator;
  final String sdk;
  const Device({required this.id, required this.name, required this.platform, this.emulator = false, this.sdk = ''});

  factory Device.fromJson(Map m) => Device(
        id: '${m['id']}',
        name: '${m['name']}',
        platform: '${m['targetPlatform'] ?? ''}',
        emulator: m['emulator'] == true,
        sdk: '${m['sdk'] ?? ''}',
      );

  /// android, ios, macos, windows, linux, web.
  String get family {
    final t = platform.toLowerCase();
    if (t.startsWith('android')) return 'android';
    if (t.startsWith('ios')) return 'ios';
    if (t.startsWith('darwin')) return 'macos';
    if (t.startsWith('windows')) return 'windows';
    if (t.startsWith('linux')) return 'linux';
    if (t.startsWith('web')) return 'web';
    return t;
  }
}

/// Connected devices, refreshed on demand and every so often.
class Devices extends ChangeNotifier {
  Devices._();
  static final Devices instance = Devices._();

  List<Device> list = const [];
  bool loading = false;
  String? error;
  String? selectedId;
  Timer? _timer;

  Device? get selected => list.where((d) => d.id == selectedId).firstOrNull ?? list.firstOrNull;

  void watch() {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading || !Sdk.instance.ready) return;
    loading = true;
    notifyListeners();
    try {
      final r = await Sdk.instance.run(['devices', '--machine'], timeout: const Duration(seconds: 60));
      final out = '${r.stdout}';
      final start = out.indexOf('[');
      list = start < 0
          ? const []
          : (jsonDecode(out.substring(start)) as List).whereType<Map>().map(Device.fromJson).toList();
      error = null;
      if (selectedId != null && list.every((d) => d.id != selectedId)) selectedId = null;
    } catch (e) {
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void select(String id) {
    selectedId = id;
    notifyListeners();
  }
}
