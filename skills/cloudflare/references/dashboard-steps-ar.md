# Owner's Cloudflare dashboard steps (Arabic)

Instructions for Claude: send the owner only the section needed for the current step, filled with this server's
values (`<SITE>`, the expression with `<SUBPATH>` if any). Cloudflare renames menus from time to time; if a menu is
not where the text says, tell the owner to search the dashboard for the feature name. Never ask the owner for an API
token or password; everything here is done by the owner in the browser. After each section, verify from the server
and report back (the verification command is noted under each section, in English, for Claude).

---

## §1 نقل إدارة النطاق إلى Cloudflare (إن لم يكن قد تم)

**قبل النقل بيوم:** في لوحة مزوّد النطاق الحالي خفّض مدة التخزين (TTL) لسجلات الموقع إلى 300 ثانية.

1. في Cloudflare: **Add a site** ← اكتب النطاق ← اختر الخطة (المجانية تكفي للبداية).
2. يستورد Cloudflare السجلات تلقائياً. **قارن كل سجل مع اللوحة القديمة سطراً بسطر** (الاسم، النوع، القيمة).
   الاستيراد قد ينقص سجلات، وعلى المنصة الأولى ضاع سجل CNAME خاص بمزوّد البريد ولم يظهر الخلل لأن سجل النجمة (*) غطّاه.
3. حالة كل سجل (العمود Proxy status):
   | السجل | الحالة |
   |---|---|
   | النطاق الرئيسي و www للمنصة | **Proxied** (السحابة البرتقالية) |
   | سجلات البريد MX وأسماء خوادم البريد | **DNS only** (رمادية) دائماً |
   | سجلات CNAME و TXT الخاصة بمزوّد البريد (DKIM، نطاق الارتداد bounce، SPF) | **DNS only** |
   | أي موقع آخر على الخادم نفسه | نقرر معاً لكل موقع (أرسل لك القائمة) |
4. صدّر نسخة من السجلات: **DNS ← Records ← Export** واحفظ الملف (هو طريقة التراجع).
5. عند مسجّل النطاق (Registrar) غيّر خوادم الأسماء (Nameservers) إلى الاسمين اللذين يعطيك إياهما Cloudflare.
6. لا تحذف المنطقة في اللوحة القديمة قبل أسبوع.

*Claude verifies:* `bash scripts/cf-discover.sh` (behind Cloudflare: yes), `bash scripts/origin-exposure.sh`.

---

## §3 قاعدة التخزين المؤقت لملفات Moodle الثابتة

1. افتح النطاق ← **Caching** ← **Cache Rules** ← **Create rule**.
2. الاسم: `Moodle static`.
3. اختر **Custom filter expression** ثم **Edit expression** والصق النص الذي أرسلته لك كما هو.
4. **Cache eligibility:** اختر **Eligible for cache**.
5. **Edge TTL:** اختر **Use cache-control header if present, bypass cache if not**.
6. **Browser TTL:** اختر **Respect origin TTL**.
7. لا تفعّل أي خيار آخر (خاصة: لا تتجاهل نص الاستعلام Query string، ولا تختر Cache Everything).
8. اضغط **Deploy** وأخبرني لأتحقق.

**التراجع:** من القائمة نفسها أطفئ القاعدة (زر التفعيل بجانبها) أو احذفها. لا حاجة لمسح الذاكرة المؤقتة.

*Claude verifies:* `bash scripts/cf-cache-check.sh` (static MISS→HIT, dynamic never HIT).

---

## §4 وضع التشفير بين Cloudflare والخادم: Full (strict)

اختبرتُ قبل هذه الخطوة أن شهادة الخادم صالحة لكل أسماء المنصة وأن تجديدها يعمل من خلف Cloudflare.
1. افتح النطاق ← **SSL/TLS** ← **Overview** ← **Configure** (أو اختيار الوضع مباشرة).
2. اختر **Full (strict)** ثم **Save**.
3. أخبرني فوراً؛ سأتحقق لمدة عشر دقائق أن كل الأسماء تعمل.

**التراجع:** الصفحة نفسها ← اختر **Full** ← Save. لا تختر **Flexible** أبداً: يجعل الاتصال بين Cloudflare والخادم غير مشفّر.

*Claude verifies:* every proxied name 200/30x through Cloudflare, no 526 (references/ssl-and-renewal.md).

---

## §5 خيارات في Cloudflare تتعارض مع Moodle أو تفيده

| الخيار | أين (قد يتغير المكان) | المطلوب | السبب |
|---|---|---|---|
| Rocket Loader | Speed ← Optimization ← Content Optimization | **إيقاف** | يغيّر طريقة تحميل ملفات البرمجة فيتعطل جزء من صفحات Moodle |
| Email Address Obfuscation | Scrape Shield | **إيقاف** | يعدّل محتوى الصفحات |
| Auto Minify (إن ظهر) | Speed ← Optimization | **إيقاف** | Moodle يضغط ملفاته بنفسه |
| Always Online | Caching ← Configuration | **إيقاف** | قد يعرض صفحات قديمة |
| 0-RTT | Network | **إيقاف** | يسمح بإعادة إرسال الطلبات (خطر على النماذج) |
| HTTP/3 و TLS 1.3 | Network / SSL/TLS ← Edge Certificates | **تشغيل** | اتصال أسرع على الجوال |
| Minimum TLS Version | SSL/TLS ← Edge Certificates | **TLS 1.2** | إيقاف الإصدارات القديمة غير الآمنة |
| Always Use HTTPS | SSL/TLS ← Edge Certificates | **تشغيل** (بعد اختبار تجديد الشهادة) | كل الزيارات مشفرة |
| Bot Fight Mode | Security ← Bots | **بحذر**: جرّب تطبيق Moodle على الجوال بعد تفعيله | قد يمنع التطبيق والأدوات الآلية ولا يمكن استثناؤها في الخطة المجانية |
| I'm Under Attack | Security ← Settings | **فقط أثناء هجوم فعلي** | يعطّل تطبيق الجوال وخدمات الويب |

*Claude verifies:* `bash scripts/cf-discover.sh` (no Rocket Loader / obfuscation markers, no challenge on the login page).

---

## §6 حذف سجل النجمة (*) بعد التأكد

بعد أن يرفض الخادم الأسماء غير المعروفة (خطوة الخادم الافتراضي)، وبعد أن أؤكد لك أن كل اسم مطلوب له سجله الخاص:
1. صدّر السجلات أولاً (DNS ← Records ← Export).
2. احذف السجل الذي اسمه `*` (وأي سجل لاسم لم يعد مستخدماً أرسله لك بالاسم).
3. أخبرني لأتحقق أن البريد والمواقع تعمل.

**التراجع:** أعد إنشاء السجل من الملف المصدّر.

*Claude verifies:* `bash scripts/origin-exposure.sh` (no wildcard), mail DNS checks of the mail module, vhost probes.

---

## §7 اختبار من جهازك (خارج الخادم)

لنتأكد مما يراه الطلاب، افتح هذا الرابط من جوال على كل شبكة (STC، موبايلي، زين) واكتب لي قيمة `colo=`:
`https://<SITE>/cdn-cgi/trace`
القيم RUH و JED و DMM تعني مركزاً داخل المملكة؛ غيرها يعني أن الشبكة توجّه إلى مركز خارجها.
