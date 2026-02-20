# Subscription Merger (V2Ray / Clash)

A lightweight Linux service that merges multiple V2Ray/Clash subscription links into a single Base64 subscription output.

The merged output is automatically updated using systemd timer and served via nginx.

---

## 🚀 One-Line Install

```bash
curl -fsSL https://raw.githubusercontent.com/ghamirizadi/Subbscribtion_Merger/main/install.sh | sudo bash
```

---

## ▶️ Run the App (Open the Management Menu)

```bash
sudo v2subagg
```

---

## 📌 How It Works

1. Add multiple subscription URLs
2. The service fetches and merges them
3. Output is Base64 encoded
4. Each config is placed on its own line
5. Available via HTTP on port 8443

---

## 🌐 Get Your Merged Subscription URL

After adding links, select option:

```
3) Show merged URL
```

Example output:

```
http://YOUR_SERVER_IP:8443/merged
```

You can paste this URL directly into:
- V2Ray clients
- Clash clients
- Clash Meta
- Shadowrocket
- Any compatible subscription client

---

## 🔄 Change Update Interval

Menu option:

```
4) Set update interval (minutes)
```

---

## 📂 View Merged File

Menu option:

```
7) Show merged file (raw + decoded)
```

---

## ❌ Uninstall

Menu option:

```
8) Uninstall
```

This removes:
- systemd service
- timer
- nginx config
- aggregator files

Python and nginx packages are NOT removed.

---

## 🛠 Requirements

- Linux (Debian / Ubuntu / CentOS / etc.)
- systemd
- root access (sudo)

Dependencies (installed automatically if missing):
- python3
- nginx

# Subscription Merger (V2Ray / Clash)

A lightweight Linux service that merges multiple V2Ray/Clash subscription links into a single Base64 subscription output.

سرویسی سبک برای لینوکس که چند لینک سابسکریپشن V2Ray / Clash را دریافت می‌کند و آن‌ها را در یک خروجی واحد (Base64) تجمیع می‌کند.

---

## 🚀 نصب با یک دستور (One-Line Install)

```bash
curl -fsSL https://raw.githubusercontent.com/ghamirizadi/Subbscribtion_Merger/main/install.sh | sudo bash
```

این دستور:
- Python3 را در صورت نبود نصب می‌کند
- Nginx را در صورت نبود نصب می‌کند
- سرویس systemd می‌سازد
- تایمر به‌روزرسانی خودکار ایجاد می‌کند
- فایل خروجی merged را آماده می‌کند

---

## ▶️ اجرای برنامه (باز کردن منو)

```bash
sudo v2subagg
```

با اجرای این دستور منوی مدیریتی باز می‌شود.

---

## 📌 نحوه کارکرد برنامه

1. چند لینک سابسکریپشن اضافه می‌کنید  
2. سرویس آن‌ها را دریافت و تجمیع می‌کند  
3. خروجی به صورت Base64 ساخته می‌شود  
4. هر کانفیگ در یک خط جدا قرار می‌گیرد  
5. خروجی از طریق Nginx روی پورت 8443 در دسترس است  

---

## 🌐 دریافت لینک نهایی سابسکریپشن

از داخل منو گزینه زیر را انتخاب کنید:

```
3) Show merged URL
```

نمونه خروجی:

```
http://IP_SERVER:8443/merged
```

این لینک را می‌توانید مستقیم داخل برنامه‌های زیر وارد کنید:

- V2Ray
- Clash
- Clash Meta
- Shadowrocket
- هر کلاینت سازگار با سابسکریپشن

---

## 🔄 تغییر زمان به‌روزرسانی خودکار

در منو گزینه:

```
4) Set update interval (minutes)
```

مثلاً اگر وارد کنید `30`  
هر ۳۰ دقیقه سابسکریپشن‌ها مجدد دریافت و تجمیع می‌شوند.

---

## 📂 مشاهده فایل خروجی ساخته شده

در منو گزینه:

```
7) Show merged file (raw + decoded)
```

نمایش می‌دهد:

- نسخه خام Base64
- نسخه decode شده (هر کانفیگ در یک خط)

---

## ❌ حذف کامل نصب (Uninstall)

در منو گزینه:

```
8) Uninstall
```

این گزینه موارد زیر را حذف می‌کند:

- سرویس systemd
- تایمر به‌روزرسانی
- تنظیمات nginx
- فایل‌های پروژه

⚠️ پکیج‌های Python و Nginx حذف نمی‌شوند.

---

## 🛠 پیش‌نیازها

- Linux (Ubuntu / Debian / CentOS / …)
- systemd
- دسترسی root یا sudo

در صورت نبود، موارد زیر به صورت خودکار نصب می‌شوند:

- python3
- nginx

---

## 📡 مسیر فایل‌ها در سرور

| مسیر | توضیح |
|------|--------|
| `/opt/v2subagg` | اسکریپت تجمیع |
| `/etc/v2subagg/config.json` | تنظیمات |
| `/var/www/sub/merged.txt` | خروجی Base64 |
| `/usr/local/bin/v2subagg` | برنامه مدیریتی |

---

## 🧠 مزایا

✔ تجمیع چند سابسکریپشن در یک لینک  
✔ حذف کانفیگ‌های تکراری  
✔ به‌روزرسانی خودکار  
✔ خروجی سازگار با V2Ray و Clash  
✔ نصب فقط با یک دستور  
✔ حذف کامل از داخل منو  

---

## 🔐 نکته امنیتی

به صورت پیش‌فرض خروجی روی HTTP و پورت 8443 اجرا می‌شود.

در صورت نیاز می‌توانید:
- دامنه تنظیم کنید
- SSL (Let's Encrypt) فعال کنید
- پشت CDN قرار دهید

---

## 📌 اجرای سریع پس از نصب

```bash
sudo v2subagg
```

---

## 👨‍💻 Developer

GitHub:
https://github.com/ghamirizadi/Subbscribtion_Merger
