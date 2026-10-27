import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/map_data.dart';

/// Service repositori peta untuk memuat data peta dari asset bundel aplikasi.
class MapRepository {
  static const String defaultMapAssetPath = 'assets/maps/map.json';

  MapData? _cachedMapData;

  /// Mengambil data peta dari cache bila sudah pernah dimuat.
  MapData? get cachedMapData => _cachedMapData;

  /// Memuat peta dari asset bundle, mem-parsing, dan memvalidasinya.
  /// User akhir TIDAK mengimpor file; peta dimuat otomatis dari asset aplikasi.
  Future<MapData> loadFromAsset([String assetPath = defaultMapAssetPath]) async {
    if (_cachedMapData != null) {
      return _cachedMapData!;
    }

    final String jsonString;
    try {
      jsonString = await rootBundle.loadString(assetPath);
    } catch (e) {
      throw MapValidationException(
        'Gagal membaca asset denah "$assetPath". Pastikan file terdaftar di pubspec.yaml: $e',
      );
    }

    return parseAndValidate(jsonString);
  }

  /// Mem-parsing string JSON dan menjalankan validasi integritas graf.
  MapData parseAndValidate(String jsonString) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(jsonString);
    } catch (e) {
      throw MapValidationException('Format JSON tidak valid: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const MapValidationException('Struktur root JSON harus berupa objek Map.');
    }

    final MapData mapData;
    try {
      mapData = MapData.fromJson(decoded);
    } on MapValidationException {
      rethrow;
    } catch (e) {
      throw MapValidationException('Gagal memproses struktur denah: $e');
    }

    // Jalankan validasi integritas (ID unik, edge valid, koordinat valid, graf tersambung)
    mapData.validate();

    _cachedMapData = mapData;
    return mapData;
  }

  /// Menghapus cache peta (berguna untuk testing atau reload).
  void clearCache() {
    _cachedMapData = null;
  }
}
