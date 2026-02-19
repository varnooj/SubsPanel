# SubsPanel — پنل ساده مدیریت سابسکریپشن‌ V2Ray

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
  - کپی لینک (b64 و raw)
- خروجی سابسکریپشن:
  - **b64**: `/s/<token>` (پیش‌فرض مناسب کلاینت‌ها)
  - **raw**: `/s/<token>?b64=0`
- نصب خودکار روی Ubuntu با Nginx + HTTPS (Let’s Encrypt)
<<<<<<< HEAD
=======
- امکان اجرای پنل روی **پورت HTTPS دلخواه** (مثلاً 8443 / 2053 / 2083 / 2087 / 2096)
>>>>>>> bd91ad1 (Fix installer: ssl first-run + rate-limit file + custom ports + renew docs)

---

## پیش‌نیازها

- Ubuntu (ترجیحاً 22.04/24.04)
- یک دامنه که A-record آن روی IP سرور ست شده باشد  
<<<<<<< HEAD
  مثال: `blog.example.com -> YOUR_SERVER_IP`
- پورت‌های باز روی فایروال/پنل سرور:
  - `80` (برای گرفتن SSL)
  - `443` (برای دسترسی HTTPS)
=======
  مثال: `sub.example.com -> YOUR_SERVER_IP`
- پورت‌های باز روی فایروال/پنل سرور:
  - `80` (برای گرفتن و تمدید SSL)
  - `HTTPS_PORT` (مثلاً `8443`)
>>>>>>> bd91ad1 (Fix installer: ssl first-run + rate-limit file + custom ports + renew docs)

> اگر DNS درست نباشد یا پورت 80 بسته باشد، گرفتن گواهی SSL با certbot شکست می‌خورد.

---
<<<<<<< HEAD
=======
## دستورات کاربردی
systemctl status subpanel --no-pager
systemctl restart subpanel
journalctl -u subpanel -n 200 --no-pager

## کانفیگ Nginx:

/etc/nginx/sites-available/subpanel

/etc/nginx/sites-enabled/subpanel

##بعد از نصب

صفحه ورود:
https://YOUR_DOMAIN:HTTPS_PORT/login

پنل ادمین:
https://YOUR_DOMAIN:HTTPS_PORT/admin

لینک‌های سابسکریپشن

لینک اصلی (b64):
https://YOUR_DOMAIN:HTTPS_PORT/s/<token>

لینک خام (raw):
https://YOUR_DOMAIN:HTTPS_PORT/s/<token>?b64=0


>>>>>>> bd91ad1 (Fix installer: ssl first-run + rate-limit file + custom ports + renew docs)

## نصب سریع (One-liner)

روی سرور با کاربر root اجرا کنید:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/varnooj/SubsPanel/main/subpanel/install.sh)
