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

## AR Navigation (Full Flutter / Tanpa Unity)

Aplikasi menyediakan fitur navigasi **Augmented Reality (AR) native murni di Flutter/Dart** tanpa ketergantungan pada Unity maupun `flutter_unity_widget`.

Fitur AR ini merender:
1. **Chevron/Panah 3D di Lantai:** Ditransformasikan dari koordinat lokal meter denah ke piksel layar melalui model kamera lubang jarum perspektif 3D (`ARProjector`). Panah membesar saat dekat dan mengecil saat jauh dengan efek denyut neon berjalan.
2. **Indikator Arah Tepi Layar:** Jika pengguna menghadap ke arah yang salah atau waypoint rute berada di luar layar, panah navigasi tepi layar memandu arah belok (*Belok Kiri*, *Belok Kanan*, atau *Putar Balik*).
3. **Pin Melayang Slot Tujuan:** Saat mendekati slot tujuan (< 18 m), pin 3D berdenyut di atas slot parkir target.
4. **Kalibrasi Posisi Awal via QR:** Scan QR di tiang/lobby berisi Node ID atau JSON `{"node":"c_l1","heading":90}` untuk menyetel posisi awal dan offset kompas. Sedia juga fallback slider manual.
5. **Dead Reckoning & Pedometer:** Estimasi langkah kaki dari accelerometer (`sensors_plus`) + heading kompas (`flutter_compass`) dengan low-pass filter, di-snap otomatis ke graf jalan denah.
6. **Mode Simulasi AR:** Tersedia tombol mode simulasi agar rute AR dapat didemokan tanpa harus berjalan fisik.
7. **HUD & Mini-Map:** Menampilkan instruksi *turn-by-turn*, sisa jarak, ETA, dan denah 2D kecil di pojok layar.

## Peta JSON (Indoor AR Map Editor)

Aplikasi smartparking secara otomatis memuat denah indoor dari asset bundel `assets/maps/map.json` hasil ekspor **Indoor AR Map Editor**. Pengguna akhir tidak perlu mengimpor file secara manual.

### Alur Programmer:
1. Desain atau edit denah pada **Indoor AR Map Editor** (`indoor_map_editor.html`).
2. Ekspor file JSON dari editor.
3. Simpan / salin file tersebut ke `assets/maps/map.json` di project ini (jangan ubah format strukturnya).
4. Pastikan `assets/maps/map.json` sudah terdaftar di `pubspec.yaml` bagian `flutter > assets`.
5. Build ulang aplikasi (`flutter run` atau `flutter build`), selesai!

### Format Struktur JSON:
```json
{
  "version": 1,
  "coordinateSystem": {
    "unit": "meter",
    "origin": "top-left",
    "yAxis": "down"
  },
  "floors": [
    {
      "id": "L1",
      "name": "Lantai 1",
      "width": 40,
      "length": 25,
      "northOffset": 0,
      "nodes": [
        { "id": "n1", "name": "pintu masuk teras", "type": "entrance", "x": 23.0, "y": 24.5 }
      ],
      "edges": [
        { "id": "e1", "from": "n1", "to": "n2", "distance": 0.5 }
      ]
    }
  ]
}
```

### Karakteristik & Aturan Denah:
- **Sumbu Koordinat:** Sumbu X ke kanan, sumbu Y mengarah ke bawah (`top-left` origin). Jarak dalam meter. Bobot edge menggunakan field `distance` dari JSON (bila null, dihitung jarak Euclidean).
- **Tipe Node:**
  - `room`: Ruangan yang dapat dijadikan tujuan.
  - `toilet`: Toilet (tersedia fitur pintasan "Cari Toilet Terdekat").
  - `entrance`: Pintu / akses masuk (termasuk pintu ruangan, bukan hanya gerbang gedung).
  - `slot`: Slot parkir kendaraan (fitur cari slot kosong aktif otomatis jika tipe slot tersedia).
  - `stairs` / `elevator`: Tangga / Lift penghubung lantai.
  - `junction`: Titik persimpangan lorong berkendara/berjalan (otomatis disaring dan TIDAK muncul sebagai tujuan navigasi pengguna).
- **Multi-Lantai:**
  - Jika JSON memiliki lebih dari 1 lantai, aplikasi secara otomatis menampilkan dropdown pemilih lantai di AppBar.
  - Jika tidak ada edge penghubung antar lantai bertipe `stairs` atau `elevator`, rute A* dibatasi per lantai yang sedang aktif.
- **Validasi Otomatis Integritas Graf:**
  - ID node unik secara lokal per lantai dan global.
  - Setiap edge wajib menunjuk node `from` dan `to` yang terdaftar.
  - Koordinat numerik valid (tidak NaN / infinite).
  - Graf per lantai harus tersambung penuh (*connected graph* tanpa node terisolasi).
  - Jika validasi gagal, aplikasi menampilkan layar error informatif yang jelas dengan tombol *Coba Lagi* (tanpa membuat aplikasi crash).
- **Kode QR Kalibrasi AR:**
  - Format isi QR: ID node langsung (misal `"n5"`) atau JSON `{"node":"n5","heading":90}`.
  - Posisi awal pengguna dikalibrasi ke koordinat node tersebut.

### Keterbatasan
- Ini adalah **pseudo-AR berbasis sensor** (kompas + accelerometer), bukan SLAM (*Simultaneous Localization and Mapping*) atau visual odometry.
- Akurasi estimasi posisi menurun seiring jarak berjalan akibat akumulasi kesalahan (*drift*), dan sensor kompas magnetik dapat mengalami interferensi logam/struktur beton bertulang di dalam basement parkir.
- Oleh karena itu, kode QR kalibrasi dirancang untuk ditempel di beberapa titik strategis (seperti pintu lobby, persimpangan lorong, dan tiang penanda).

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