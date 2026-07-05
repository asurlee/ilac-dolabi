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
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const IlacDolabiApp());

class IlacDolabiApp extends StatelessWidget {
  const IlacDolabiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'İlaç Dolabı',
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

  if (gtin == null) return null; // GTIN yoksa geçerli ilaç karekodu değil
  return Ilac(gtin: gtin, seriNo: seri, partiNo: parti, sonKullanma: skt);
}

int _degiskenSonu(String s, int basla, String gs) {
  final idx = s.indexOf(gs, basla);
  return idx == -1 ? s.length : idx;
}

DateTime? _tarihCevir(String yyaagg) {
  if (yyaagg.length != 6) return null;
  final yil = 2000 + int.parse(yyaagg.substring(0, 2));
  final ay = int.parse(yyaagg.substring(2, 4));
  var gun = int.parse(yyaagg.substring(4, 6));
  // Gün 00 ise ayın son günü demektir
  if (gun == 0) gun = DateTime(yil, ay + 1, 0).day;
  return DateTime(yil, ay, gun);
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
    final ham = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const TarayiciSayfa()),
    );
    if (ham == null) return;
    final ilac = karekoduParcala(ham);
    if (ilac == null) {
      _mesaj('Bu karekod bir ilaç karekodu gibi görünmüyor.');
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
// Kamera tarayıcı ekranı
// ---------------------------------------------------------------------------
class TarayiciSayfa extends StatefulWidget {
  const TarayiciSayfa({super.key});
  @override
  State<TarayiciSayfa> createState() => _TarayiciSayfaState();
}

class _TarayiciSayfaState extends State<TarayiciSayfa> {
  // Kamera nesnesi burada (sabit) oluşturulur, build içinde DEĞİL.
  // autoStart: false -> başlatmayı biz elle yapıyoruz (daha güvenilir).
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.dataMatrix, BarcodeFormat.qrCode],
  );
  bool _okundu = false;

  @override
  void initState() {
    super.initState();
    _basla();
  }

  Future<void> _basla() async {
    try {
      await _controller.start();
    } catch (_) {
      // Hata olursa aşağıdaki errorBuilder ekranda gösterecek.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Karekodu kameraya gösterin')),
      body: MobileScanner(
        controller: _controller,
        // Kamera açılamazsa gerçek hatayı ekranda göster
        errorBuilder: (context, error, child) {
          return Container(
            color: Colors.black,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(24),
            child: Text(
              'Kamera açılamadı.\n\n'
              'Hata: ${error.errorCode}\n'
              '${error.errorDetails?.message ?? ''}',
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          );
        },
        onDetect: (capture) {
          if (_okundu) return;
          if (capture.barcodes.isEmpty) return;
          final ham = capture.barcodes.first.rawValue;
          if (ham != null) {
            _okundu = true;
            Navigator.pop(context, ham);
          }
        },
      ),
    );
  }
}
