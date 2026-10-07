# Smart Indoor Parking

Aplikasi mobile (Flutter) untuk **navigasi di dalam area parkir gedung/perusahaan**, seperti Google Maps tetapi untuk indoor parking.

Pengguna masuk lobby → melihat kondisi slot secara realtime → mendapat slot kosong terdekat → mengikuti rute → jika slot tujuan tiba-tiba terisi, aplikasi otomatis mencari slot lain dan melakukan **dynamic rerouting**.

> Repositori ini hanya berisi sisi **mobile app**. Sensor parkir, IoT, backend, database, dan API dikerjakan oleh tim lain.

## Fitur

- Denah parking map 2D: lobby, slot, posisi pengguna, dan rute
- Status slot realtime (hijau = tersedia, merah = terisi)
- Pemilihan slot kosong berdasarkan **panjang rute terpendek** (algoritma A*)
- Route preview dan navigasi (Start / Stop Navigation)
- **Dynamic rerouting** saat slot tujuan berubah menjadi terisi
- Navigasi AR (panah di lantai) lewat modul Unity + Immersal *(rencana)*

## Status Pengembangan

| Tahap | Isi | Status |
|---|---|---|
| 1 | Denah 2D, model data, A*, pemilihan slot, rerouting (data dummy) | Selesai |
| 2 | Denah asli (SVG/PNG) sebagai layer dasar peta | Belum |
| 3 | Integrasi API + WebSocket/SSE dari backend | Belum |
| 4 | Jembatan Flutter ke Unity (`flutter_unity_widget`) | Belum |
| 5 | AR navigation (Unity + Immersal), penyelarasan koordinat | Belum |

## Arsitektur

```
lib/
├── main.dart
├── models/
│   └── parking_models.dart          # Node, Edge, ParkingSlot, Lobby, ParkingLayout, SlotUpdate
├── services/
│   ├── a_star.dart                  # Algoritma A* dan utilitas polyline
│   ├── parking_repository.dart      # Kontrak ke backend + MockParkingRepository
│   └── navigation_controller.dart   # Logika pemilihan slot, rute, dan rerouting
├── widgets/
│   └── map_painter.dart             # CustomPainter untuk denah, slot, rute, pengguna
└── pages/
    └── map_page.dart                # Halaman utama peta dan navigasi
```

Pembagian tanggung jawab:

- **`ParkingRepository`**: satu-satunya pintu ke backend. Saat ini memakai `MockParkingRepository`. Ganti dengan implementasi HTTP + WebSocket tanpa mengubah logika lain.
- **`NavigationController`** (`ChangeNotifier`): menyimpan state navigasi dan menjalankan rerouting. UI hanya membaca state-nya.
- **`AStar`**: menghitung rute di graf jalur (node dan edge dalam meter).

## Cara Menjalankan

Prasyarat: Flutter SDK terpasang (`flutter doctor` tanpa error) dan emulator atau perangkat Android.

```bash
git clone <url-repositori>
cd smartparking
flutter pub get
flutter run
```

### Mencoba dynamic rerouting

1. Pilih lobby masuk (misalnya Lobby 1).
2. Tekan **Start Navigation**. Aplikasi memilih slot kosong dengan rute terpendek.
3. Saat titik biru bergerak, tekan **Simulasi: slot tujuan terisi**.
4. Aplikasi membatalkan slot lama, memilih slot kosong lain, dan menggambar rute baru.

## Data yang Dibutuhkan dari Backend

Aplikasi mengasumsikan backend menyediakan data berikut. Semua koordinat dalam **meter**, relatif ke denah.

**Layout (diambil sekali, misalnya `GET /layout`):**

```json
{
  "width": 50,
  "height": 16,
  "lobbies": [{ "id": "L1", "name": "Lobby 1", "entryNodeId": "c0" }],
  "nodes": [{ "id": "c0", "x": 0.0, "y": 10.0 }],
  "edges": [{ "from": "c0", "to": "c1" }],
  "slots": [
    { "id": "A2", "lobbyId": "L1", "x": 10.0, "y": 4.0, "status": "available" }
  ]
}
```

**Update slot (stream realtime, WebSocket atau SSE):**

```json
{ "slotId": "A2", "status": "occupied" }
```

> Nama endpoint dan field di atas masih asumsi. Sesuaikan dengan kontrak API yang disepakati bersama tim backend.

## Rencana Integrasi AR

AR dipakai sebagai media visualisasi, bukan fitur terpisah. Logika rute tetap di Flutter.

1. Flutter menghitung rute (A*) dan mengirim daftar titik sebagai JSON ke Unity (`NavigationController.routeJsonForUnity()`).
2. Unity menaruh model panah (chevron) di tiap titik dan mengarahkannya ke titik berikutnya.
3. Immersal (visual positioning) memberi posisi HP di ruangan nyata, sehingga panah menempel di lantai.
4. Saat rerouting, Flutter mengirim rute baru dan Unity mengganti panahnya.

Catatan teknis yang perlu diselesaikan:

- Koordinat denah (meter) harus diselaraskan dengan koordinat peta Immersal (offset, rotasi, skala).
- Uji hasil scan Immersal di area parkir yang sebenarnya, karena pemandangan parkir cenderung berulang dan redup.
- Cek kompatibilitas versi `flutter_unity_widget` dengan versi Flutter dan Unity yang dipakai.
- Cek lisensi dan batasan versi gratis Immersal.

## Rencana Pengembangan

- [ ] Layer denah asli (SVG/PNG) di bawah slot dan rute
- [ ] Implementasi `ParkingRepository` untuk API dan WebSocket asli
- [ ] Snap posisi pengguna ke edge graf terdekat (map matching)
- [ ] Rerouting dari titik tengah edge, bukan dari node terdekat
- [ ] Deteksi lobby otomatis (geofence atau BLE)
- [ ] Halaman route preview
- [ ] Jembatan Flutter-Unity dan tampilan AR
- [ ] Mode mini-map/suara saat berkendara
- [ ] Unit test untuk A* dan logika rerouting

## Teknologi

- Flutter (Dart), `CustomPainter`, `InteractiveViewer`
- State management: `ChangeNotifier` + `ListenableBuilder` (bisa dimigrasi ke Riverpod/Bloc)
- AR (rencana): Unity, Immersal, `flutter_unity_widget`

## Lisensi

Tentukan lisensi proyek di sini.