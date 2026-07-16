// İlaç Dolabı - Ev ilaç envanteri
//
// Özellikler:
//   - Karekod (GS1 DataMatrix) okuyup ilacı listeye ekler
//   - İlaç adı ve türü (Tablet/Krem/Şurup...) gömülü listeden bulunur
//   - Türe göre gruplanmış liste
//   - Son kullanma tarihine 7 gün kala ve son gün bildirim
//   - Süresi geçenler ana listeden çıkar, "Atılacaklar" bölümüne düşer

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

final FlutterLocalNotificationsPlugin _bildirim =
    FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ilacListesiniYukle();
  await bildirimleriBaslat();
  runApp(const IlacDolabiApp());
}

// ---------------------------------------------------------------------------
// Bildirim altyapısı
// ---------------------------------------------------------------------------
Future<void> bildirimleriBaslat() async {
  try {
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Europe/Istanbul'));
    await _bildirim.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    final android = _bildirim.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  } catch (_) {
    // Bildirim kurulamazsa uygulama yine çalışsın
  }
}

class IlacDolabiApp extends StatelessWidget {
  const IlacDolabiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'İlaç Dolabı',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const AnaSayfa(),
    );
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
class Ilac {
  final String gtin;
  final String? seriNo;
  final String? partiNo;
  final DateTime? sonKullanma;
  String ad;
  String form; // Tablet / Krem / Şurup ...

  Ilac({
    required this.gtin,
    this.seriNo,
    this.partiNo,
    this.sonKullanma,
    this.ad = 'Bilinmiyor',
    this.form = 'Diğer',
  });

  Map<String, dynamic> toJson() => {
        'gtin': gtin,
        'seriNo': seriNo,
        'partiNo': partiNo,
        'sonKullanma': sonKullanma?.toIso8601String(),
        'ad': ad,
        'form': form,
      };

  factory Ilac.fromJson(Map<String, dynamic> j) => Ilac(
        gtin: j['gtin'],
        seriNo: j['seriNo'],
        partiNo: j['partiNo'],
        sonKullanma: j['sonKullanma'] != null
            ? DateTime.tryParse(j['sonKullanma'])
            : null,
        ad: j['ad'] ?? 'Bilinmiyor',
        form: j['form'] ?? 'Diğer',
      );
}

// ---------------------------------------------------------------------------
// Karekod çözümleme (GS1)
// ---------------------------------------------------------------------------
Ilac? karekoduParcala(String ham) {
  String s = ham;
  const gs = '\u001d';
  if (s.startsWith(']d2') || s.startsWith(']Q3')) s = s.substring(3);

  String? gtin, seri, parti;
  DateTime? skt;
  int i = 0;

  while (i < s.length - 1) {
    final ai = s.substring(i, i + 2);
    i += 2;
    switch (ai) {
      case '01':
        if (i + 14 <= s.length) {
          gtin = s.substring(i, i + 14);
          i += 14;
        }
        break;
      case '17':
        if (i + 6 <= s.length) {
          skt = _tarihCevir(s.substring(i, i + 6));
          i += 6;
        }
        break;
      case '21':
        final son = _degiskenSonu(s, i, gs);
        seri = s.substring(i, son);
        i = son;
        break;
      case '10':
        final son = _degiskenSonu(s, i, gs);
        parti = s.substring(i, son);
        i = son;
        break;
      default:
        i = _degiskenSonu(s, i, gs);
    }
    if (i < s.length && s[i] == gs) i++;
  }

  // Ayraçsız kodlar için yedek yöntem
  if (gtin == null || skt == null) {
    final duz = s.replaceAll(gs, '');
    gtin ??= RegExp(r'^01(\d{14})').firstMatch(duz)?.group(1) ??
        RegExp(r'01(\d{14})').firstMatch(duz)?.group(1);
    if (skt == null) {
      for (final m in RegExp(r'17(\d{6})').allMatches(duz)) {
        final aday = _tarihCevir(m.group(1)!);
        if (aday != null && aday.year >= 2015 && aday.year <= 2060) {
          skt = aday;
          break;
        }
      }
    }
  }

  if (gtin == null) return null;
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
  if (ay < 1 || ay > 12 || gun > 31) return null;
  final tamYil = 2000 + yil;
  if (gun == 0) gun = DateTime(tamYil, ay + 1, 0).day;
  return DateTime(tamYil, ay, gun);
}

String tarihYaz(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

// ---------------------------------------------------------------------------
// İlaç adı + türü listesi (assets/ilaclar.csv -> "barkod<TAB>ad<TAB>tür")
// ---------------------------------------------------------------------------
final Map<String, String> _barkodAd = {};
final Map<String, String> _barkodForm = {};

Future<void> ilacListesiniYukle() async {
  try {
    final metin = await rootBundle.loadString('assets/ilaclar.csv');
    for (final satir in const LineSplitter().convert(metin)) {
      final p = satir.split('\t');
      if (p.length >= 3) {
        _barkodAd[p[0]] = p[1];
        _barkodForm[p[0]] = p[2];
      }
    }
  } catch (_) {}
}

String _barkodaCevir(String gtin) {
  var b = gtin;
  while (b.length > 13 && b.startsWith('0')) {
    b = b.substring(1);
  }
  return b;
}

String gtinDenAdBul(String gtin) =>
    _barkodAd[_barkodaCevir(gtin)] ?? 'Bilinmiyor (GTIN: $gtin)';

String gtinDenFormBul(String gtin) =>
    _barkodForm[_barkodaCevir(gtin)] ?? 'Diğer';

// Grupların ekranda görünme sırası
const List<String> formSirasi = [
  'Tablet', 'Kapsül', 'Şurup', 'Süspansiyon', 'Damla', 'Krem', 'Merhem',
  'Jel', 'Losyon/Şampuan', 'Sprey', 'İnhaler', 'Ampul/Enjeksiyon',
  'Fitil/Ovül', 'Toz/Granül/Şase', 'Solüsyon', 'Bant/Flaster', 'Diğer',
];

const Map<String, IconData> formSimgesi = {
  'Tablet': Icons.medication,
  'Kapsül': Icons.medication_liquid,
  'Şurup': Icons.local_drink,
  'Süspansiyon': Icons.local_drink,
  'Damla': Icons.water_drop,
  'Krem': Icons.sanitizer,
  'Merhem': Icons.sanitizer,
  'Jel': Icons.sanitizer,
  'Losyon/Şampuan': Icons.soap,
  'Sprey': Icons.air,
  'İnhaler': Icons.air,
  'Ampul/Enjeksiyon': Icons.vaccines,
  'Fitil/Ovül': Icons.healing,
  'Toz/Granül/Şase': Icons.grain,
  'Solüsyon': Icons.science,
  'Bant/Flaster': Icons.medical_services,
  'Diğer': Icons.inventory_2,
};

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
      final list =
          (jsonDecode(kayit) as List).map((e) => Ilac.fromJson(e)).toList();
      // Eski kayıtların adı/türü eksikse tamamla
      for (final il in list) {
        if (il.ad.startsWith('Bilinmiyor')) il.ad = gtinDenAdBul(il.gtin);
        if (il.form == 'Diğer') il.form = gtinDenFormBul(il.gtin);
      }
      setState(() => _ilaclar = list);
      _kaydet();
    }
    _bildirimleriKur();
  }

  Future<void> _kaydet() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'ilaclar', jsonEncode(_ilaclar.map((e) => e.toJson()).toList()));
  }

  // Her değişiklikte tüm hatırlatmaları yeniden kurar
  Future<void> _bildirimleriKur() async {
    try {
      await _bildirim.cancelAll();
      const detay = NotificationDetails(
        android: AndroidNotificationDetails(
          'skt_kanali',
          'Son kullanma hatırlatmaları',
          channelDescription:
              'İlaçların son kullanma tarihi yaklaşınca hatırlatır',
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      final simdi = tz.TZDateTime.now(tz.local);
      var id = 0;
      for (final il in _ilaclar) {
        final skt = il.sonKullanma;
        if (skt == null) continue;
        // 7 gün kala ve son gün, saat 10:00'da
        for (final gunOnce in [7, 0]) {
          final zaman = tz.TZDateTime(tz.local, skt.year, skt.month, skt.day, 10)
              .subtract(Duration(days: gunOnce));
          if (!zaman.isAfter(simdi)) continue;
          await _bildirim.zonedSchedule(
            id: id++,
            title: gunOnce == 7
                ? 'Son kullanma tarihi yaklaşıyor'
                : 'Son kullanma tarihi bugün',
            body: gunOnce == 7
                ? '${il.ad} — 7 gün sonra (${tarihYaz(skt)}) süresi doluyor.'
                : '${il.ad} — bugün son kullanma tarihi. Atmayı unutmayın.',
            scheduledDate: zaman,
            notificationDetails: detay,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          );
        }
      }
    } catch (_) {}
  }

  Future<void> _tara() async {
    final ham = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const TarayiciSayfa()),
    );
    if (ham == null) return;
    if (!mounted) return; // tarama ekranı kapandıysa devam etme
    final ilac = karekoduParcala(ham);
    if (ilac == null) {
      _hamGoster(ham);
      return;
    }
    // 1) Tıpatıp aynı KUTU mu? (seri no her kutuda benzersizdir)
    if (ilac.seriNo != null && ilac.seriNo!.isNotEmpty) {
      final ayniKutu = _ilaclar
          .any((e) => e.gtin == ilac.gtin && e.seriNo == ilac.seriNo);
      if (ayniKutu) {
        _mesaj('Bu kutu zaten listede, tekrar eklenmedi.');
        return;
      }
    }
    // 2) Aynı ilaçtan zaten var mı? Ayrı kutu olabilir -> kullanıcıya sor
    final mevcut = _ilaclar.where((e) => e.gtin == ilac.gtin).length;
    if (mevcut > 0) {
      final ad = gtinDenAdBul(ilac.gtin);
      final ekle = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Bu ilaç zaten listede'),
          content: Text('$ad\n\nListede $mevcut kutu kayıtlı. '
              'Bu ayrı bir kutu mu, yoksa aynı kutuyu mu okuttunuz?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Aynı kutu, ekleme')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ayrı kutu, ekle')),
          ],
        ),
      );
      if (ekle != true) return;
      if (!mounted) return;
    }
    ilac.ad = gtinDenAdBul(ilac.gtin);
    ilac.form = gtinDenFormBul(ilac.gtin);
    setState(() => _ilaclar.add(ilac));
    _kaydet();
    _bildirimleriKur();
  }

  void _mesaj(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // İsim/tür elle düzeltme: listede olmayan ilaçlar için
  Future<void> _duzenle(Ilac il) async {
    final adKutusu = TextEditingController(
        text: il.ad.startsWith('Bilinmiyor') ? '' : il.ad);
    String secilenForm = il.form;
    final kaydet = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, yenile) => AlertDialog(
          title: const Text('İlacı düzenle'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: adKutusu,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'İlaç adı',
                  hintText: 'Örn: FLAGYL 500 MG 20 FILM TABLET',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('Türü:'),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: secilenForm,
                      items: formSirasi
                          .map((f) =>
                              DropdownMenuItem(value: f, child: Text(f)))
                          .toList(),
                      onChanged: (v) =>
                          yenile(() => secilenForm = v ?? 'Diğer'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('GTIN: ${il.gtin}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Vazgeç')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Kaydet')),
          ],
        ),
      ),
    );
    if (kaydet != true) return;
    final ad = adKutusu.text.trim();
    setState(() {
      if (ad.isNotEmpty) il.ad = ad;
      il.form = secilenForm;
    });
    _kaydet();
  }

  void _sil(Ilac il) {
    setState(() => _ilaclar.remove(il));
    _kaydet();
    _bildirimleriKur();
  }

  void _gecmisleriSil(List<Ilac> gecmisler) {
    setState(() => _ilaclar.removeWhere(gecmisler.contains));
    _kaydet();
    _bildirimleriKur();
    _mesaj('${gecmisler.length} ilaç listeden silindi.');
  }

  void _hamGoster(String ham) {
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
              SelectableText(ham.replaceAll('\u001d', '|'),
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Tamam')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bugun = DateTime.now();
    final bugunBas = DateTime(bugun.year, bugun.month, bugun.day);

    // Süresi geçenleri ayır
    final gecmisler = _ilaclar
        .where((i) => i.sonKullanma != null && i.sonKullanma!.isBefore(bugunBas))
        .toList();
    final gecerliler =
        _ilaclar.where((i) => !gecmisler.contains(i)).toList();

    // Türe göre grupla
    final gruplar = <String, List<Ilac>>{};
    for (final il in gecerliler) {
      gruplar.putIfAbsent(il.form, () => []).add(il);
    }
    for (final l in gruplar.values) {
      l.sort((a, b) => (a.sonKullanma ?? DateTime(2100))
          .compareTo(b.sonKullanma ?? DateTime(2100)));
    }

    final govde = <Widget>[];
    for (final form in formSirasi) {
      final liste = gruplar[form];
      if (liste == null || liste.isEmpty) continue;
      govde.add(_baslik(form, liste.length));
      govde.addAll(liste.map((il) => _kart(il, bugunBas)));
    }
    if (gecmisler.isNotEmpty) {
      govde.add(_gecmisBaslik(gecmisler));
      govde.addAll(gecmisler.map((il) => _kart(il, bugunBas, gecmis: true)));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('İlaç Dolabım (${_ilaclar.length})'),
      ),
      body: _ilaclar.isEmpty
          ? const Center(
              child: Text('Henüz ilaç yok.\nAlttaki butonla karekod okut.',
                  textAlign: TextAlign.center))
          : ListView(padding: const EdgeInsets.only(bottom: 88), children: govde),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _tara,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Karekod Oku'),
      ),
    );
  }

  Widget _baslik(String form, int adet) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Row(children: [
          Icon(formSimgesi[form] ?? Icons.inventory_2,
              size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text('$form  ($adet)',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.primary)),
        ]),
      );

  Widget _gecmisBaslik(List<Ilac> gecmisler) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 8, 6),
        child: Row(children: [
          const Icon(Icons.delete_forever, size: 20, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Süresi Geçmiş — Atılacak (${gecmisler.length})',
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Colors.red)),
          ),
          TextButton(
            onPressed: () => _gecmisleriSil(gecmisler),
            child: const Text('Hepsini sil'),
          ),
        ]),
      );

  Widget _kart(Ilac il, DateTime bugunBas, {bool gecmis = false}) {
    final skt = il.sonKullanma;
    String alt;
    Color? renk;
    if (skt == null) {
      alt = 'Son kullanma: okunamadı';
    } else {
      final kalan = skt.difference(bugunBas).inDays;
      alt = 'Son kullanma: ${tarihYaz(skt)}';
      if (gecmis) {
        alt += '  •  süresi doldu';
        renk = Colors.red;
      } else if (kalan <= 7) {
        alt += '  •  $kalan gün kaldı';
        renk = Colors.orange.shade800;
      }
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: gecmis ? Colors.red.withValues(alpha: 0.06) : null,
      child: ListTile(
        onTap: () => _duzenle(il),
        title: Text(il.ad),
        subtitle: Text(alt, style: TextStyle(color: renk)),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _sil(il),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canlı tarayıcı ekranı
// ---------------------------------------------------------------------------
class TarayiciSayfa extends StatefulWidget {
  const TarayiciSayfa({super.key});
  @override
  State<TarayiciSayfa> createState() => _TarayiciSayfaState();
}

class _TarayiciSayfaState extends State<TarayiciSayfa> {
  bool _okundu = false;
  bool _uyardi = false;
  bool _ters = false;   // siyah zemin üzerine BEYAZ karekod için
  bool _fener = false;
  MobileScannerController _kontrol = MobileScannerController();

  @override
  void initState() {
    super.initState();
    _baslat(_kontrol);
  }

  // Widget kamerayı kendi başlatıyorsa buradaki hata yutulur, sorun olmaz.
  Future<void> _baslat(MobileScannerController k) async {
    try {
      await k.start();
    } catch (_) {}
  }

  @override
  void dispose() {
    _kontrol.dispose();
    super.dispose();
  }

  void _bitir(String ham) {
    if (_okundu) return;
    _okundu = true;
    Navigator.pop(context, ham);
  }

  // Ters renk modu: bazı kutularda karekod siyah zemine beyaz basılır.
  // Normal okuyucular bunu göremez; görüntüyü ters çevirince okunur.
  Future<void> _tersDegistir() async {
    final eski = _kontrol;
    final yeniTers = !_ters;
    final yeni = MobileScannerController(invertImage: yeniTers);
    setState(() {
      _ters = yeniTers;
      _kontrol = yeni;
      _fener = false;
    });
    await eski.dispose();
    await _baslat(yeni);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(yeniTers
          ? 'Ters renk AÇIK — siyah zemine beyaz karekodlar için'
          : 'Ters renk kapalı — normal karekodlar için'),
    ));
  }

  Future<void> _fenerDegistir() async {
    try {
      await _kontrol.toggleTorch();
      setState(() => _fener = !_fener);
    } catch (_) {}
  }

  Future<void> _fotoyla() async {
    final XFile? foto = await ImagePicker()
        .pickImage(source: ImageSource.camera, imageQuality: 100);
    if (foto == null) return;
    // Fotoğrafta da aynı ters renk ayarını kullan
    final controller = MobileScannerController(invertImage: _ters);
    String? ham;
    try {
      final sonuc = await controller.analyzeImage(foto.path);
      if (sonuc != null && sonuc.barcodes.isNotEmpty) {
        ham = sonuc.barcodes.first.rawValue;
      }
    } catch (_) {}
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
        title: Text(_ters ? 'Ters renk modu' : 'Karekodu okutun'),
        actions: [
          IconButton(
            tooltip: 'Ters renk (siyah zemine beyaz karekod)',
            icon: Icon(Icons.invert_colors,
                color: _ters ? Colors.amber : null),
            onPressed: _tersDegistir,
          ),
          IconButton(
            tooltip: 'Fener',
            icon: Icon(_fener ? Icons.flash_on : Icons.flash_off),
            onPressed: _fenerDegistir,
          ),
          IconButton(
            tooltip: 'Fotoğraf çekerek oku',
            icon: const Icon(Icons.photo_camera),
            onPressed: _fotoyla,
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            key: ValueKey(_ters),
            controller: _kontrol,
            onDetect: (capture) {
              if (_okundu) return;
              for (final b in capture.barcodes) {
                final kare = b.format == BarcodeFormat.dataMatrix ||
                    b.format == BarcodeFormat.qrCode;
                if (kare && b.rawValue != null) {
                  _bitir(b.rawValue!);
                  return;
                }
              }
              if (!_uyardi) {
                _uyardi = true;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  duration: Duration(seconds: 4),
                  content: Text('Çizgili barkod değil, KARE karekodu okutun.'),
                ));
              }
            },
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: _ters ? Colors.amber : Colors.tealAccent,
                      width: 3),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          // Alt bilgi çubuğu
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              padding: const EdgeInsets.all(12),
              child: Text(
                _ters
                    ? 'Ters renk açık. Normale dönmek için üstteki damla simgesine bas.'
                    : 'Okumuyorsa: karekod SİYAH zemine BEYAZ basılmış olabilir.\n'
                        'Üstteki damla simgesine basıp tekrar dene.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
