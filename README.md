# SubsPanel — V2Ray پنل ساده مدیریت سابسکریپشن‌ 

یک پنل خیلی سبک و ساده برای ساخت و مدیریت لینک‌های سابسکریپشن که کانفیگ‌ها را **خودتان دستی paste** می‌کنید.  
پنل فقط **یک ادمین** دارد و خروجی سابسکریپشن را هم به صورت **Base64 (برای v2rayN و اکثر کلاینت‌ها)** و هم **Raw** ارائه می‌دهد.

---


## ویژگی‌ها

- صفحه لاگین ادمین (یک یوزر/پسورد)
- ایجاد سابسکریپشن با **نام** + **متن کانفیگ‌ها**
- لیست سابسکریپشن‌ها + عملیات:
  - ویرایش
  - غیرفعال‌سازی/فعال‌سازی
  - حذف
  - تعویض URL (Rotate Token)
  - کپی لینک (b64 و raw)
  - QR Code
- خروجی سابسکریپشن:
  - **b64**: `/s/<token>` (پیش‌فرض مناسب کلاینت‌ها)
  - **raw**: `/s/<token>?b64=0`
- نصب خودکار روی Ubuntu با Nginx + HTTPS (Let’s Encrypt)
- امکان اجرای پنل روی **پورت HTTPS دلخواه** (مثلاً 8443 / 2053 / 2083 / 2087 / 2096)

---

## پیش‌نیازها

- Ubuntu (ترجیحاً 22.04/24.04)
- دامنه‌ای که A-record آن روی IP سرور ست شده باشد  
  مثال: `sub.example.com -> YOUR_SERVER_IP`
- پورت‌های باز روی فایروال/پنل سرور:
  - `80` (برای گرفتن و تمدید SSL)
  - `HTTPS_PORT` (مثلاً `8443` یا `2096`)

> نکته: QR Code از طریق مسیر `/qr` روی **همان پورت HTTPS پنل** لود می‌شود و پورت جداگانه‌ای نیاز ندارد.

---

## نصب سریع (One-liner)

روی سرور با کاربر `root` اجرا کنید:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/varnooj/SubsPanel/main/install.sh)
```

ورودی‌های نصب (Installer Prompts)

اسکریپت نصب از شما می‌پرسد:

Domain
مثال: sub.example.com

Admin username

Admin password

Internal app port (مثلاً 8000 یا 8001)
این پورت فقط روی لوکال (127.0.0.1) استفاده می‌شود و مستقیم از بیرون در دسترس نیست.

HTTPS port (مثلاً 8443 یا 2096)
این همان پورتی است که کاربران با آن پنل را باز می‌کنند.

بعد از نصب
صفحه ورود

https://YOUR_DOMAIN:HTTPS_PORT/login

پنل ادمین

https://YOUR_DOMAIN:HTTPS_PORT/admin

لینک‌های سابسکریپشن

لینک اصلی (b64):
https://YOUR_DOMAIN:HTTPS_PORT/s/<token>

لینک خام (raw):
https://YOUR_DOMAIN:HTTPS_PORT/s/<token>?b64=0


مسیر فایل‌ها (روی سرور)

پروژه:
/opt/subpanel

فایل env (حاوی یوزر/پسورد/Secret):
/etc/subpanel.env

سرویس:
/etc/systemd/system/subpanel.service

کانفیگ nginx:

/etc/nginx/sites-available/subpanel

/etc/nginx/sites-enabled/subpanel

دستورات کاربردی

وضعیت سرویس:

systemctl status subpanel --no-pager

ریستارت سرویس:

systemctl restart subpanel

دیدن لاگ‌ها:

journalctl -u subpanel -n 200 --no-pager

تست سلامت پنل از لوکال:

curl -I http://127.0.0.1:INTERNAL_PORT/login
تست QR (عیب‌یابی)
تست مستقیم از لوکال (روی سرور)
curl -s -o /tmp/qr.png "http://127.0.0.1:INTERNAL_PORT/qr?url=https://example.com"
file /tmp/qr.png
ls -lh /tmp/qr.png

اگر درست باشد باید چیزی شبیه این ببینید:

PNG image data ...

تست از بیرون (روی دامنه)
curl -k -I "https://YOUR_DOMAIN:HTTPS_PORT/qr?url=https://example.com"

باید:

Status = 200

Content-Type: image/png


پیشنهاد: پسورد قوی انتخاب کنید و Rate Limit روی /login در Nginx فعال باشد.

Troubleshooting
1) QR سفید است یا لود نمی‌شود

اول مطمئن شوید endpoint /qr روی سرویس داخلی وجود دارد:

curl -I "http://127.0.0.1:INTERNAL_PORT/qr?url=https://example.com"

اگر 404 بود: یعنی نسخه‌ی app.py شما /qr ندارد یا سرویس آپدیت نشده است.

سرویس را ریستارت کنید و مطمئن شوید فایل‌های پروژه درست deploy شده‌اند.

2) certbot خطا می‌دهد

DNS باید درست باشد و پورت 80 باز باشد.

لاگ:
/var/log/letsencrypt/letsencrypt.log


