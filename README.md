# moodle-server-care

مهارات Claude Code لرعاية خوادم Moodle الإنتاجية خطوةً خطوة، مأخوذة من تجربة معالجة فعلية لخادم إنتاج.
Claude Code skills for caring for production Moodle servers, distilled from a real production remediation.

## الوحدات / Modules

| الأمر | ماذا تفعل |
|---|---|
| `/moodle-server-care:start` | اكتشاف الخادم (قراءة فقط)، وإنشاء دليل الخادم وسجل العمليات، واقتراح الوحدة التالية |
| `/moodle-server-care:audit` | فحص أداء وأمن للقراءة فقط، ومراقبة 48 ساعة، وتقرير عربي للفريق |
| `/moodle-server-care:cloudflare` | عنوان IP الحقيقي، والتخزين المؤقت، وحد الرفع، ووضع SSL، واختبار تجديد الشهادة |
| `/moodle-server-care:mail` | البريد في الخلفية عبر خادم بريد محلي، وSPF وDKIM وDMARC ونطاق الارتداد |
| `/moodle-server-care:nginx` | رفض النطاقات المجهولة، وصدّ أدوات الفحص، وحدود الطلبات (تسجيل ثم تفعيل) |
| `/moodle-server-care:tuning` | جدولة المهام، والتخزين المؤقت، وتثبيت الإضافات بأمان، ورقع الموردين |
| `/moodle-server-care:hygiene` | الشهادات الميتة، وتدوير السجلات، وصلاحيات ملفات الأسرار، والمشاريع المتروكة |
| `/moodle-server-care:backup` | نسخ ليلي مشفّر إلى SharePoint (Microsoft 365) أو تخزين متوافق مع S3، مع تنبيه واختبار استعادة |
| `/moodle-server-care:maintenance` | ليلة صيانة معلنة: لافتة عد تنازلي، وكلمات مرور Redis وقاعدة البيانات، وإعادة التشغيل |
| `/moodle-server-care:monitoring` | تنبيه فوري على تيليجرام عند تعطل الموقع أو الخادم أو قاعدة البيانات: فحص خارجي (UptimeRobot) وفحص على الخادم كل دقيقة (healthchecks.io) |

كل وحدة تبدأ بفحص للقراءة فقط وتقترح خطة، ولا تغيّر شيئاً قبل موافقة المالك. وكل تغيير يمر بنسخة احتياطية ثم اختبار ثم
تحقق مع طريقة رجوع، ويُسجَّل في سجل العمليات على الخادم. القواعد المشتركة في `shared/core-rules.md`.

## التثبيت على خادم / Installing on a server

The repository is private, so the server needs read access to it (an SSH key or a token that can read the repo).

1. In a Claude Code session on the server:
   ```
   /plugin marketplace add wabualela/moodle-server-care
   /plugin install moodle-server-care@moodle-server-care
   ```
   Or clone it and add the local folder as a marketplace: `/plugin marketplace add /path/to/moodle-server-care`.
2. Start with `/moodle-server-care:start`, then run the modules it recommends, or only the one you need.

## أدوات على جهازك / Tools for your own computer

`tools/grant-temp-sudo.sh`: يعرض خوادمك من `~/.ssh/config` لتختار منها، ثم يمنح sudo بلا كلمة مرور لمستخدم لمدة
تحددها (30m، 2h، 3d، 1w، أو موعد محدد)، ويزيله تلقائياً مؤقّت systemd بتاريخ ثابت يصمد أمام إعادة التشغيل. ويعرض الحالة
أو يزيل الصلاحية فوراً، ويسجّل العملية في سجل عمليات الخادم إن وُجد. يعمل على Linux وmacOS، وعلى Windows داخل Git Bash أو WSL:
```bash
bash grant-temp-sudo.sh
```

## Rules that never change
- Read-only discovery first; owner approval before every change; one change at a time; backups and rollback ready.
- No secrets in this repository, in logs or in chat: the owner inserts credentials with no-echo prompts.
- Irreversible deletions are run by the owner; the skills prepare the exact command after checking nothing uses the data.
