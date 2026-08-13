# Rapor yapısı değişikliği — geçiş rehberi

> İngilizce sürüm: [`MIGRATION.md`](MIGRATION.md). İkisi aynı şeyi anlatıyor; hangisi
> elinize geçtiyse yeterli.

Bu doküman, Collie SDK'sını **kullanmadan** kendi kodunuzla aynı Firestore'a rapor yazan
uygulamalar için. Collie SDK kullanıyorsanız geçiş = SDK'yı güncellemek (iOS 1.15.0,
Android 0.4.0); burası sadece arka plan.

Değişiklik tek cümleyle: **ham log akışı (`entries`) rapor dokümanının içinden çıkıp kendi
dokümanına taşındı.**

Burada iki konu var. Bölme zorunlu olan: yaptığınızda panelin listesi yeniden hızlanır.
Sondaki [oturum bağlamı](#isteğe-bağlı-oturum-bağlamı-panelin-katlanabilir-geçmişi) ise
isteğe bağlı ve bağımsız: panelin, raporun devraldığı geçmişi analiste kaydırtmak yerine
katlamasını sağlayan şey o.

---

## Neden

Analist panelindeki liste ekranı rapor başına dört şey gösteriyor: durum, testerın yazdığı
cümle, cihaz, tarih. Bunu çizmek için `collie_reports` koleksiyonunu okuyor.

Firestore'un web SDK'sında bir dokümanın **sadece bazı alanlarını** çekmek mümkün değil.
`select()` yok; doküman ya tamamen gelir ya hiç gelmez. Yani o dört sütunu çizmek için
dokümandaki her alan indiriliyordu — içinde `entries` de vardı: yakalanmış tüm log akışı,
her isteğin ve yanıtın gövdesiyle birlikte.

Tek başına bu bile israftı. Asıl sorunu yaratan şey testerların çalışma biçimi: uygulamayı
hiç kapatmıyorlar. Log akışı sürece bağlı olduğu için, üç gündür açık duran bir cihazdan
gelen onuncu rapor, önceki dokuz raporun trafiğini de taşıyor. Yani rapor dokümanları
**zamanla büyüyor** ve liste her yeni raporla biraz daha yavaşlıyordu. "Performans giderek
düşüyor" şikâyetinin sebebi buydu.

Ekran görüntüsü zaten tam olarak bu sebeple ayrı bir dokümanda tutuluyordu
(`collie_report_screenshots`). Log akışı da artık aynı deseni izliyor.

İki kazanç:

- Panelin liste sorgusu küçük dokümanlar taşıyor, böylece hepsini birden yüklemek yerine
  sayfalayabiliyor.
- Akışı Firestore'un 1 MiB doküman sınırına yaklaşan bir rapor artık sırf loglarının boyutu
  yüzünden reddedilme riski taşımıyor; iki parça ayrı ayrı sınırlanıyor.

---

## Wire'da ne değişiyor

**Önce** — tek doküman:

```
collie_reports/{reportId}
  appKey, status, hasScreenshot, clientReportId, createdAt,
  app, device, report, telemetry,
  entries: [ … tüm akış … ]             ← sorun burası
```

**Sonra** — aynı id'li iki doküman:

```
collie_reports/{reportId}
  appKey, status, hasScreenshot, clientReportId, createdAt,
  app, device, report, telemetry        ← entries yok

collie_report_entries/{reportId}
  appKey                                ← tekrarlanıyor, aşağıda sebebi var
  entries: [ … tüm akış … ]
  createdAt
```

`appKey` entries dokümanında bilerek tekrarlanıyor: güvenlik kuralları bu koleksiyonu kendi
başına kapsıyor. Üst dokümanı okumak zorunda kalan bir kural hem her yazma için fazladan bir
okuma maliyeti çıkarır **hem de** ilk yazmada patlar — o anda üst doküman henüz yok.

Geri kalan her şey aynı: koleksiyon adları, doküman id'si olarak rapor id'si,
`app` / `device` / `report` / `telemetry` içindeki alan adları, ekran görüntüsü dokümanı.

---

## Nasıl yapılır

### 1. Önce akışı, sonra raporu yazın

Sıra önemli. Panelin keşfettiği şey rapor dokümanı; henüz yazılmamış bir akışı işaret
etmemeli. Ekran görüntüsünde de aynı sıra geçerli.

```
1. collie_report_screenshots/{reportId} yaz   (varsa)
2. collie_report_entries/{reportId} yaz       ← yeni
3. collie_reports/{reportId} yaz              (`entries` olmadan)
```

2. adım **geçici** bir hatayla başarısız olursa (offline, timeout, unavailable) tüm raporu
sonra tekrar deneyin — rapor dokümanını yazmayın. **Kalıcı** bir hatayla başarısız olursa
(permission denied; kurallar henüz deploy edilmemiştir) eski şekle düşün: `entries`'i rapor
dokümanının içine geri koyup yazın. Büyük doküman bir performans sorunudur; akışı sessizce
düşürülmüş rapor ise kaybedilmiş bir bug.

### 2. Alanı silin, boşaltmayın

`entries` alanı rapor dokümanında **hiç bulunmamalı** — `entries: []` de olmamalı.

Panel akışı nereden okuyacağına "rapor dokümanında `entries` alanı var mı?" diye bakarak
karar veriyor, çünkü boş dizi geçerli bir cevap: logsuz bir rapor. `[]` yazarsanız panel
akışın tamamının bu olduğunu sanır ve ayrı dokümana hiç bakmaz — rapor logsuz görünür.

Merge/patch ile yazıyorsanız ve doküman önceki bir denemeden kalmış olabilirse (uygulama
güncellendikten sonraki bir retry), alanı açıkça silin — Firebase SDK'larında
`FieldValue.delete()` — yoksa eski inline kopya merge'den sağ çıkar.

### 3. Id'ler birebir aynı olsun

`collie_report_entries/{reportId}`, raporla **aynı doküman id'sini** kullanır. Retry'ın
kopya yaratmak yerine üzerine yazmasını sağlayan da budur; panel akışı böyle bulur: sorgu
atmaz, doğrudan o id'yi okur.

### 4. Güvenlik kurallarını önce deploy edin

Kurallar Collie ile geliyor: [`Integration/firestore.rules`](Integration/firestore.rules).
Buradaki iki nokta kritik:

- `collie_report_entries` için kendi bloğu gerekiyor — olmadan yeni koleksiyona her yazma
  reddedilir ve reporter'ınız sonsuza kadar inline'a düşer (doğru çalışır ama hiçbir kazanç
  elde edilmez).
- Rapor şekli kontrolü artık `entries` alanını **zorunlu tutmuyor**. Eski kurallar
  yürürlükteyken alanı yazmayan bir reporter deploy ederseniz **her rapor reddedilir**.

Yani: önce kurallar, sonra client. Ters sırada hiçbir rapor gönderilemeyeceği bir pencere
oluşur.

### 5. Eski raporlara dokunmayın

Backfill gerekmiyor. Panel iki şekli de okuyor — alan varsa önce inline, yoksa ayrı doküman
— dolayısıyla Firestore'da duran raporlar eskisi gibi açılmaya devam ediyor. Zaten kısa
ömürlüler: bir rapor Jira'ya gönderildikten ve saklama süresi dolduktan sonra siliniyor.

---

## Kontrol listesi

- [ ] `Integration/firestore.rules` deploy edildi, `collie_report_entries` bloğu dahil
- [ ] Reporter `collie_report_entries/{reportId}` dokümanını `appKey` + `entries`
      (+ `createdAt`) ile yazıyor
- [ ] Rapor dokümanında artık `entries` yok — alan **mevcut değil**, boş değil
- [ ] Entries dokümanı rapor dokümanından **önce** yazılıyor
- [ ] Geçici hata → tüm rapor retry; kalıcı hata → inline'a düş
- [ ] Retry'lar üç doküman için de aynı rapor id'sini kullanıyor
- [ ] Test raporu gönderildi ve panelde doğrulandı: rapor açılıyor, log akışı yerinde, ağ ve
      navigasyon listeleri dolu

Sonuncusu diğerlerinin kaçırdığı hatayı yakalar: trafik yakaladığı belli olan bir raporda log
listesinin boş görünmesi, panelin gerçek bir akış ya da olmayan bir alan beklerken
`entries: []` bulduğu anlamına gelir.

---

## İsteğe bağlı: oturum bağlamı (panelin katlanabilir geçmişi)

Bölmenin parçası değil — daha eski, ayrı bir ekleme (SDK 1.14.0 / android-0.3.0) ve büyük
ihtimalle sizin reporter'ınız bunu henüz göndermiyor. Göndermezseniz raporlar yine çalışır;
gönderirseniz panel, raporun **gerçekten yeni olan** kısmını gömmeyi bırakır.

### Çözdüğü problem

Testerlar uygulamayı kapatmıyor. Log akışı süreç yaşadığı sürece yaşıyor, dolayısıyla bir
cihazdan gelen onuncu rapor önceki dokuz raporun navigasyon ve trafiğini de taşıyor — ve
bug'ın gerçekten ilgili olduğu birkaç satır, ilgisiz yüzlerce satırın altında kalıyor. Rapor
dokümanlarını büyüten gerçek de buydu; buradaki mesele ise çok raporu *listelemek* değil, tek
raporu *okumak*.

Çözüm sunum düzeyinde ve kayıpsız: panel, bir sınırdan eski olan her şeyi tek tıkla açılan
bir bloğa katlıyor, yeni kısmı açık bırakıyor. Hiçbir şey atılmıyor — oturum başında bir kez
atılan `appConfig` ya da `login` çağrısı katlanmış bloğun içinde, kaybolmuş değil.

### Alanlar

`report` bloğunun içinde beş **opsiyonel** alan:

| Alan | Tip | Anlamı |
|---|---|---|
| `previousReportAt` | ISO-8601 | Bu cihazın bir önceki raporunun `capturedAt` değeri. İlk raporda yok. |
| `sessionStartedAt` | ISO-8601 | Mevcut mantıksal oturumun başlangıcı. |
| `processStartedAt` | ISO-8601 | Sürecin başlangıcı — yani uygulama ne zamandır açık. |
| `sessionOrdinal` | int, 1'den başlar | Kaçıncı mantıksal oturum. |
| `sequence` | int, 1'den başlar | Bu cihazdan kaçıncı rapor. |

Panel katlama sınırını **önce `previousReportAt`'ten, o yoksa `sessionStartedAt`'ten** alıyor
(cihazın ilk raporu için). İkisini de göndermezseniz sınır oluşmaz ve rapor bugünkü gibi
görünür — bu alanların opsiyonel kalması şart olmasının sebebi de bu: Firestore'da duran
raporların hiçbiri bunları taşımıyor.

`processStartedAt`, `sessionOrdinal` ve `sequence` katlama sınırını etkilemiyor. Bunlar
panelin listelerin üstüne yazdığı bilgi ("3. rapor · 2. oturum · 3 gündür açık") — yani
raporun **neden** katlanmış açıldığını açıklayan bağlam.

### İşi yapan ya da bozan üç kural

1. **Her timestamp UTC offset taşımalı.** Sınır, `previousReportAt` ile girdi zaman
   damgalarının *karşılaştırılmasıyla* bulunuyor. Offsetsiz bir damga analistin tarayıcı saat
   diliminde okunur ve katlamayı saatlerce kaydırır — sessizce, üstelik formatlama sorunu
   gibi değil veri sorunu gibi görünerek.

2. **`sequence`, `sessionOrdinal` ve `previousReportAt` süreç öldürülünce kaybolmamalı.**
   Kalıcı depoya yazın (`UserDefaults` / `SharedPreferences` / muadili) ve başarılı bir
   gönderimden sonra `previousReportAt`'i o raporun kendi `capturedAt` değeriyle güncelleyin.
   `processStartedAt` bilerek süreçle birlikte sıfırlanan tek alan.

3. **Mantıksal oturum her foreground dönüşünde değil, uzun bir arka plandan sonra yeniden
   başlar.** Collie **30 dakikalık** bir arka plan eşiği kullanıyor ve bu iki platformda
   birebir aynı — "tester yemekten döndü" ile "tester on saniyeliğine başka uygulamaya geçti"
   arasını ayıran şey bu. Aynı değeri kullanın; eşik farklı olursa aynı tester davranışı
   farklı noktalarda katlanır ve ekranda bunu gerçek bir farktan ayırt etmenin yolu olmaz.

### Oturum işaretleri (önerilir)

Collie ayrıca akışa, kendi kronolojik yerlerine sentetik girdiler ekliyor; hepsi
`category: "collie"` taşıyor. Panel bunları log satırı olarak değil, etiketli bir ayraç
olarak çiziyor — böylece analist oturum sınırlarını zaman çizelgesinde görebiliyor:

| Zaman damgası | `message` |
|---|---|
| `processStartedAt` | `Session started — <biçimlenmiş tarih>` |
| `previousReportAt` | `Previous report submitted` |
| her resume | `Session resumed after <n> min background` |

Ortadaki en önemlisi ve zaman damgası **tam olarak** `previousReportAt` olmalı: panel, sınıra
eşit olan girdiyi katlamanın *yeni* tarafında tutuyor, dolayısıyla bu işaret katlanmış bloğun
hemen altına, "önceki rapor burada bitti" satırı olarak düşüyor.

İşaretler, **host'un tek bir girdisini bile yeniden sıralamadan, düşürmeden veya
değiştirmeden** ekleniyor — her işaret, kendi zaman damgasından önceki ya da ona eşit tüm
girdilerden sonra geliyor. Akış kayıpsız kalıyor.

### Çıktıda nasıl görünüyor

Panelde eski yarı tek satırlık katlanmış bir blok. Jira issue'sunda ise olamıyor: Jira Data
Center'ın wiki renderer'ında katlanabilir makro **hiç yok** (`{expand}` bir *Confluence*
makrosu ve Jira'ya eklenmesi talebi "Won't Fix" ile kapatıldı). Bu yüzden panel o yarıyı
"Önceki bağlam" başlığı altında, bu raporun kendi satırlarının **altına** koyuyor — aynı
içerik, ama ticket'ın konusu olan istekleri gömemeyecek bir konumda.

---

## Firestore index'leri (panel tarafı)

Client değişikliğinin parçası değil ama aynı geçişin parçası: panelin sayfalı listesi
`collie_reports` üzerinde iki composite index istiyor.

| Alanlar | Kullanan |
|---|---|
| `appKey` ASC, `createdAt` DESC | Admin olmayan analistin liste sorgusu |
| `appKey` ASC, `bridgedAt` ASC | Saklama süresi temizliği |

Ayrıca liste artık `createdAt`'e göre sıralı. Firestore, sıralama alanını taşımayan
dokümanları sorgu sonucuna hiç katmaz — yani **her rapor `createdAt` taşımak zorunda**, yoksa
panelde hiç görünmez.
