# قالب: أمر لا رجعة فيه ينفذه المالك بنفسه

> تعليمات لـ Claude (بالإنجليزية): use this when an approved step is irreversible (delete, truncate, purge) or when
> the session's permission system refused it. Run every read-only pre-check first and paste their results in short.
> One command per message, exact paths, no globs (or `sudo sh -c '…'` for paths under /root). After the owner runs
> it: verify (`test ! -e`, `stat`, `df -h`) and append a log entry "owner ran it; checked by session <name>".

---

**أمر تنفّذه أنت — لا يمكن التراجع عنه**

**ماذا يفعل:** <وصف قصير، مثل: يحذف ملف تصدير بيانات الطلاب القديم `<PATH>` (الحجم <SIZE>، آخر تعديل <DATE>)>.

**لماذا هو آمن الآن (تحققت من ذلك):**
- لا يشير إليه أي موقع مفعّل ولا مهمة مجدولة ولا خدمة، ولا يفتحه أي برنامج الآن.
- <شرط إضافي، مثل: أصلحنا السبب ولم يتغير الملف منذ <TIME>، أو: توجد نسخة مؤرشفة في `/root/<TOPIC>-cleanup-<DATE>`>.

**الأمر (انسخه كما هو في الطرفية):**
```
<EXACT COMMAND>
```

**بعد التنفيذ:** أخبرني بكلمة «تم» لأتحقق من النتيجة وأسجّل العملية في سجل العمليات باسمك.

> ملاحظة: نظام الأذونات في جلستي يمنعني من تنفيذ أوامر الحذف النهائي حتى بعد موافقتك، وهذا مقصود للحماية، لذلك
> أجهّز الأمر وتنفذه أنت.
