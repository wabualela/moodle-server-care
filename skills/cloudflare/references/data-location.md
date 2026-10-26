# Data location and personal-data law (PDPL caveat)

Not legal advice. Claude's job is to make the decision visible to management and record it, not to decide.

## What changes when Cloudflare proxies a Moodle site
- Cloudflare terminates TLS at its edge. It processes every request and response in clear text: session cookies,
  login form posts (usernames and passwords), page content, uploaded files, grades shown on pages. This is true even
  for pages it does not cache.
- Which edge processes a request depends on the visitor's network route; it may be outside the country even when
  in-country edges exist. Cloudflare's core services (logs, analytics, security) may run elsewhere.
- Cloudflare offers regional controls (the Data Localization Suite: regional services, customer metadata boundary)
  on Enterprise plans. Free and Pro have no such guarantee.
- Cloudflare publishes a Data Processing Addendum (DPA) that applies to its customers; management should check it
  covers their needs.
- If backups or files are also stored with Cloudflare (R2) with client-side encryption, Cloudflare stores data it
  cannot read; that is a different kind of processing from the proxy, which reads traffic.

## Saudi Arabia (PDPL) specifically
- The Personal Data Protection Law (regulator: SDAIA) has been enforceable since September 2024. Transfers of
  personal data outside the Kingdom are allowed only under its transfer regulation (adequacy, appropriate safeguards
  such as standard contractual clauses or binding corporate rules, or listed exceptions), with data minimisation
  and, in some cases, a transfer risk assessment.
- Hosting the server itself outside the Kingdom is already a transfer; Cloudflare adds a processor on top.
- Government-linked entities may also fall under the NCA Essential Cybersecurity Controls and Cloud Cybersecurity
  Controls, which can require in-Kingdom hosting with a registered provider; accredited e-learning may fall under
  National eLearning Center (NELC) standards.
- Other countries: apply the local law (GDPR in the EU/UK, etc.); the same questions apply.

## Questions for management (send in Arabic)
```markdown
## قرار مطلوب: معالجة Cloudflare لبيانات زيارات المنصة

عند تشغيل المنصة خلف Cloudflare يفك Cloudflare تشفير الزيارات في مراكزه ليتمكن من حمايتها وتسريعها، فيمرّ عبره
كل ما يرسله الطالب ويستقبله: بيانات الدخول، وملفات الجلسة، ومحتوى الصفحات والدرجات المعروضة. قد تكون المراكز التي
تعالج الزيارة خارج المملكة بحسب مسار شبكة الطالب، ولا تتوفر ضمانات لمكان المعالجة إلا في خطة المؤسسات (Enterprise).

نحتاج قراركم في:
1. هل معالجة Cloudflare لبيانات الزيارات مقبولة وفق موقفنا من نظام حماية البيانات الشخصية؟ وبأي خطة؟
2. هل يلزم أن تتم المعالجة داخل المملكة (يتطلب خطة المؤسسات أو استضافة داخلية)؟
3. من يوثّق أساس نقل البيانات (العقد/البنود التعاقدية) في سجل أنشطة المعالجة؟

هذه ليست استشارة قانونية؛ نقترح عرضها على المسؤول القانوني أو مسؤول حماية البيانات.
```

## Record
Write the decision, its date and who decided in the server handbook (section 1 "CDN/proxy" line and the plan), and
in the operations log as an n.a. entry ("decision recorded"). If the decision is "no", the module stops at the
real-IP step (harmless) and the owner grey-clouds the records.
