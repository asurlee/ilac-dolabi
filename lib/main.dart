// İlaç Dolabı - Ev ilaç envanteri uygulaması
// Karekod (GS1 DataMatrix) okuyup ilacı listeye ekler.
//
// Çalışan kısımlar:
//   - Kamerayla DataMatrix okuma
//   - Karekodu parçalama: GTIN, son kullanma tarihi, seri no, parti no
//   - İlaçları telefonda kalıcı saklama (uygulamayı kapatınca silinmez)
//
// Senin tamamlaman gereken tek kısım (kodda "TODO" olarak işaretli):
//   - GTIN -> ilaç adı eşleştirmesi (TİTCK barkod listesinden)

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const IlacDolabiApp());

class IlacDolabiApp extends StatelessWidget {
  const IlacDolabiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'İlaç Dolabı',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const AnaSayfa(),
    );
  }
}

// ---------------------------------------------------------------------------
// Bir ilaç kaydını temsil eden model
// ---------------------------------------------------------------------------
class Ilac {
  final String gtin;
  final String? seriNo;
  final String? partiNo;
  final DateTime? sonKullanma;
  String ad;        // GTIN'den bulunacak

  Ilac({
    required this.gtin,
    this.seriNo,
    this.partiNo,
    this.sonKullanma,
    this.ad = 'Bilinmiyor',
  });

  Map<String, dynamic> toJson() => {
        'gtin': gtin,
        'seriNo': seriNo,
        'partiNo': partiNo,
        'sonKullanma': sonKullanma?.toIso8601String(),
        'ad': ad,
      };

  factory Ilac.fromJson(Map<String, dynamic> j) => Ilac(
        gtin: j['gtin'],
        seriNo: j['seriNo'],
        partiNo: j['partiNo'],
        sonKullanma: j['sonKullanma'] != null
            ? DateTime.tryParse(j['sonKullanma'])
            : null,
        ad: j['ad'] ?? 'Bilinmiyor',
      );
}

// ---------------------------------------------------------------------------
// GS1 DataMatrix karekodunu parçalayan fonksiyon
//
// Karekoddaki alanlar (Application Identifier - AI):
//   01 -> GTIN, sabit 14 hane
//   17 -> son kullanma tarihi, sabit 6 hane (YYAAGG)
//   21 -> seri no, değişken uzunluk
//   10 -> parti no, değişken uzunluk
//
// Değişken alanlar bir ayraç karakteriyle (FNC1 / GS, kod 29) biter.
// ---------------------------------------------------------------------------
Ilac? karekoduParcala(String ham) {
  // Bazı okuyucular başa fazladan karakter ekler, temizle
  String s = ham.replaceAll('\u001d', '\u001d'); // GS karakterini koru
  const gs = '\u001d'; // FNC1 ayraç

  String? gtin, seri, parti;
  DateTime? skt;

  int i = 0;
  // Eğer string ] ile başlıyorsa (sembol tanımlayıcı), atla
  if (s.startsWith(']d2') || s.startsWith(']Q3')) s = s.substring(3);

  while (i < s.length - 1) {
    final ai = s.substring(i, i + 2);
    i += 2;
    switch (ai) {
      case '01': // GTIN - 14 hane sabit
        if (i + 14 <= s.length) {
          gtin = s.substring(i, i + 14);
          i += 14;
        }
        break;
      case '17': // son kullanma - 6 hane sabit (YYAAGG)
        if (i + 6 <= s.length) {
          skt = _tarihCevir(s.substring(i, i + 6));
          i += 6;
        }
        break;
      case '21': // seri no - değişken
        final son = _degiskenSonu(s, i, gs);
        seri = s.substring(i, son);
        i = son;
        break;
      case '10': // parti no - değişken
        final son = _degiskenSonu(s, i, gs);
        parti = s.substring(i, son);
        i = son;
        break;
      default:
        // Bilinmeyen AI: bir sonraki ayraca atla, takılmamak için
        final son = _degiskenSonu(s, i, gs);
        i = son;
    }
    // Ayraç karakterini atla
    if (i < s.length && s[i] == gs) i++;
  }

  // Yedek yöntem: Bazı kutularda ayraç (GS) karakteri hiç bulunmaz.
  // O zaman yukarıdaki sıralı okuma şaşabilir. Burada kodun içinde
  // doğrudan GTIN ve geçerli bir tarih arıyoruz.
  if (gtin == null || skt == null) {
    final duz = s.replaceAll(gs, ''); // ayraçları at

    // GTIN: tercihen en baştaki "01" + 14 hane
    gtin ??= RegExp(r'^01(\d{14})').firstMatch(duz)?.group(1) ??
        RegExp(r'01(\d{14})').firstMatch(duz)?.group(1);

    // Son kullanma: "17" + 6 hane olan ve MANTIKLI bir tarih veren ilk eşleşme
    if (skt == null) {
      for (final m in RegExp(r'17(\d{6})').allMatches(duz)) {
        final aday = _tarihCevir(m.group(1)!);
        if (aday != null &&
            aday.year >= 2000 &&
            aday.year <= 2060 &&
            aday.isAfter(DateTime(2015))) {
          skt = aday;
          break;
        }
      }
    }
  }

  if (gtin == null) return null; // GTIN yoksa geçerli ilaç karekodu değil
  return Ilac(gtin: gtin, seriNo: seri, partiNo: parti, sonKullanma: skt);
}

int _degiskenSonu(String s, int basla, String gs) {
  final idx = s.indexOf(gs, basla);
  return idx == -1 ? s.length : idx;
}

DateTime? _tarihCevir(String yyaagg) {
  if (yyaagg.length != 6) return null;
  final yil = int.tryParse(yyaagg.substring(0, 2));
  final ay = int.tryParse(yyaagg.substring(2, 4));
  var gun = int.tryParse(yyaagg.substring(4, 6));
  if (yil == null || ay == null || gun == null) return null;
  if (ay < 1 || ay > 12 || gun > 31) return null; // mantıksız tarih
  final tamYil = 2000 + yil;
  // Gün 00 ise ayın son günü demektir
  if (gun == 0) gun = DateTime(tamYil, ay + 1, 0).day;
  return DateTime(tamYil, ay, gun);
}

// ---------------------------------------------------------------------------
// TODO 1: GTIN'den ilaç adını bul
// TİTCK'nın yayınladığı barkod listesini (CSV) uygulamaya assets olarak
// ekleyip burada okuyabilirsin. Şimdilik küçük bir örnek tablo:
// ---------------------------------------------------------------------------
final Map<String, String> _ornekGtinAdTablosu = {
  // 'GTIN': 'İLAÇ ADI',
  '08699522705009': 'Örnek İlaç 500 mg',
};

String gtinDenAdBul(String gtin) {
  return _ornekGtinAdTablosu[gtin] ?? 'Bilinmiyor (GTIN: $gtin)';
}

// ---------------------------------------------------------------------------
// Ana ekran
// ---------------------------------------------------------------------------
class AnaSayfa extends StatefulWidget {
  const AnaSayfa({super.key});
  @override
  State<AnaSayfa> createState() => _AnaSayfaState();
}

class _AnaSayfaState extends State<AnaSayfa> {
  List<Ilac> _ilaclar = [];

  @override
  void initState() {
    super.initState();
    _yukle();
  }

  Future<void> _yukle() async {
    final prefs = await SharedPreferences.getInstance();
    final kayit = prefs.getString('ilaclar');
    if (kayit != null) {
      final list = (jsonDecode(kayit) as List)
          .map((e) => Ilac.fromJson(e))
          .toList();
      setState(() => _ilaclar = list);
    }
  }

  Future<void> _kaydet() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'ilaclar', jsonEncode(_ilaclar.map((e) => e.toJson()).toList()));
  }

  Future<void> _tara() async {
    // Canlı tarayıcı ekranını aç; okunan karekodu (ham metin) geri alır.
    final ham = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const TarayiciSayfa()),
    );
    if (ham == null) return;
    final ilac = karekoduParcala(ham);
    if (ilac == null) {
      _hamGoster(ham);
      return;
    }
    ilac.ad = gtinDenAdBul(ilac.gtin);
    setState(() => _ilaclar.add(ilac));
    _kaydet();
  }

  void _mesaj(String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  // Çözümlenemeyen kodun içeriğini göster (teşhis için)
  void _hamGoster(String ham) {
    final gorunur = ham.replaceAll('\u001d', '|'); // ayracı görünür yap
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Karekod çözümlenemedi'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Okunan içerik:'),
              const SizedBox(height: 8),
              SelectableText(
                gorunur,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                'Bu bir ilaç karekodu değilse, kutunun KARE şeklindeki '
                'karekodunu okuttuğunuzdan emin olun.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  void _sil(int i) {
    setState(() => _ilaclar.removeAt(i));
    _kaydet();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('İlaç Dolabım')),
      body: _ilaclar.isEmpty
          ? const Center(
              child: Text('Henüz ilaç yok.\nAlttaki butonla karekod okut.',
                  textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: _ilaclar.length,
              itemBuilder: (_, i) {
                final il = _ilaclar[i];
                final skt = il.sonKullanma;
                final gecmis =
                    skt != null && skt.isBefore(DateTime.now());
                return Card(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  child: ListTile(
                    title: Text(il.ad),
                    subtitle: Text(skt != null
                        ? 'Son kullanma: ${skt.day}.${skt.month}.${skt.year}'
                            '${gecmis ? '  ⚠️ GEÇMİŞ' : ''}'
                        : 'Son kullanma: okunamadı'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _sil(i),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _tara,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Karekod Oku'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canlı tarayıcı ekranı (mobile_scanner 7.x)
// Kamera otomatik başlar. Karekod görülünce ekran kapanır ve sonucu döndürür.
// Üstteki fotoğraf butonu: canlı kamera açılmazsa yedek okuma yolu.
// ---------------------------------------------------------------------------
class TarayiciSayfa extends StatefulWidget {
  const TarayiciSayfa({super.key});
  @override
  State<TarayiciSayfa> createState() => _TarayiciSayfaState();
}

class _TarayiciSayfaState extends State<TarayiciSayfa> {
  bool _okundu = false;
  bool _uyardi = false;

  void _bitir(String ham) {
    if (_okundu) return;
    _okundu = true;
    Navigator.pop(context, ham);
  }

  // Yedek yol: telefonun kamerasıyla fotoğraf çekip karekodu çöz
  Future<void> _fotoyla() async {
    final XFile? foto = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 100);
    if (foto == null) return;
    final controller = MobileScannerController();
    String? ham;
    try {
      final sonuc = await controller.analyzeImage(foto.path);
      if (sonuc != null && sonuc.barcodes.isNotEmpty) {
        ham = sonuc.barcodes.first.rawValue;
      }
    } catch (_) {
      // sessizce geç, aşağıda mesaj verilecek
    }
    await controller.dispose();
    if (!mounted) return;
    if (ham != null) {
      _bitir(ham);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Fotoğrafta karekod bulunamadı, tekrar deneyin.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Karekodu kameraya gösterin'),
        actions: [
          IconButton(
            tooltip: 'Kamera açılmazsa: fotoğraf çekerek oku',
            icon: const Icon(Icons.photo_camera),
            onPressed: _fotoyla,
          ),
        ],
      ),
      // Kontrolör vermiyoruz: widget kamerayı kendi başlatıp durduruyor.
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_okundu) return;
              // Kutunun DÜZ ÇİZGİLİ barkodunu (EAN-13 vb.) yoksay;
              // tarih bilgisi sadece KARE karekodun içinde var.
              for (final b in capture.barcodes) {
                final kare = b.format == BarcodeFormat.dataMatrix ||
                    b.format == BarcodeFormat.qrCode;
                if (kare && b.rawValue != null) {
                  _bitir(b.rawValue!);
                  return;
                }
              }
              // Kare karekod görülmediyse taramaya devam et (uyarı göster)
              if (!_uyardi) {
                _uyardi = true;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  duration: Duration(seconds: 4),
                  content: Text('Çizgili barkod değil, KARE karekodu okutun.'),
                ));
              }
            },
          ),
          // Nişangah: karekodu bu çerçeveye getir
          IgnorePointer(
            child: Center(
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.tealAccent, width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

