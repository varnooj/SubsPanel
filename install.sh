#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[-] لطفاً اسکریپت را با root اجرا کنید."
  exit 1
fi

echo "=== SubPanel Installer ==="

read -rp "آدرس سایت/دامنه (مثلاً blog.example.com): " DOMAIN
if [[ -z "${DOMAIN}" ]]; then
  echo "[-] دامنه نمی‌تواند خالی باشد."
  exit 1
fi

read -rp "پورت داخلی اپ (پیش‌فرض 8000): " APP_PORT
APP_PORT="${APP_PORT:-8000}"

read -rp "یوزر ادمین: " ADMIN_USER
if [[ -z "${ADMIN_USER}" ]]; then
  echo "[-] یوزر نمی‌تواند خالی باشد."
  exit 1
fi

read -rsp "پسورد ادمین: " ADMIN_PASS
echo
if [[ -z "${ADMIN_PASS}" ]]; then
  echo "[-] پسورد نمی‌تواند خالی باشد."
  exit 1
fi

SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"

echo "[+] Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot python3 python3-venv python3-pip

echo "[+] Creating app directory..."
mkdir -p /opt/subpanel/templates /opt/subpanel/static

echo "[+] Writing application files..."
cat > /opt/subpanel/app.py <<'PYAPP'
import base64
import os
import sqlite3
import time
import secrets
from fastapi import FastAPI, Request, Form, Response
from fastapi.responses import HTMLResponse, RedirectResponse, PlainTextResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeSerializer, BadSignature

APP_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.getenv("DB_PATH", os.path.join(APP_DIR, "db.sqlite3"))

ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("ADMIN_PASS", "change-me-strong")
SECRET_KEY = os.getenv("SECRET_KEY", secrets.token_hex(32))

serializer = URLSafeSerializer(SECRET_KEY, salt="session-v1")

app = FastAPI()
templates = Jinja2Templates(directory=os.path.join(APP_DIR, "templates"))


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = db()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS subscriptions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            token TEXT NOT NULL UNIQUE,
            content TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """
    )
    conn.commit()
    conn.close()


init_db()


def get_logged_in_user(request: Request):
    cookie = request.cookies.get("session")
    if not cookie:
        return None
    try:
        data = serializer.loads(cookie)
        return data.get("u")
    except BadSignature:
        return None


def is_admin(request: Request):
    return get_logged_in_user(request) == ADMIN_USER


def require_admin_or_redirect(request: Request):
    if not is_admin(request):
        return RedirectResponse("/login", status_code=303)
    return None


@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/admin", status_code=303)


@app.get("/login", response_class=HTMLResponse, include_in_schema=False)
def login_page(request: Request):
    return templates.TemplateResponse("login.html", {"request": request, "err": None})


@app.post("/login", include_in_schema=False)
def login(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    if username == ADMIN_USER and password == ADMIN_PASS:
        resp = RedirectResponse("/admin", status_code=303)
        resp.set_cookie(
            "session",
            serializer.dumps({"u": username, "t": int(time.time())}),
            httponly=True,
            samesite="strict",
            secure=True,  # پشت HTTPS در nginx امن می‌شود؛ اگر فقط HTTPS داری می‌تونی True کنی
        )
        return resp
    return templates.TemplateResponse(
        "login.html",
        {"request": request, "err": "نام کاربری یا رمز عبور اشتباه است."},
        status_code=401,
    )


@app.post("/logout", include_in_schema=False)
def logout():
    resp = RedirectResponse("/login", status_code=303)
    resp.delete_cookie("session")
    return resp


@app.get("/admin", response_class=HTMLResponse, include_in_schema=False)
def admin_home(request: Request):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    conn = db()
    rows = conn.execute(
        "SELECT * FROM subscriptions ORDER BY id DESC"
    ).fetchall()
    conn.close()

    base_url = f"{request.url.scheme}://{request.url.netloc}"
    return templates.TemplateResponse(
        "admin.html",
        {"request": request, "subs": rows, "base_url": base_url},
    )


@app.get("/admin/new", response_class=HTMLResponse, include_in_schema=False)
def admin_new(request: Request):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir
    return templates.TemplateResponse("new.html", {"request": request})


@app.post("/admin/create", include_in_schema=False)
def admin_create(request: Request, name: str = Form(...), content: str = Form(...)):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    token = secrets.token_urlsafe(24)
    now = int(time.time())

    conn = db()
    conn.execute(
        "INSERT INTO subscriptions (name, token, content, is_active, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)",
        (name.strip(), token, content, now, now),
    )
    conn.commit()
    conn.close()
    return RedirectResponse("/admin", status_code=303)


@app.get("/admin/edit/{sub_id}", response_class=HTMLResponse, include_in_schema=False)
def admin_edit(request: Request, sub_id: int):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    conn = db()
    row = conn.execute(
        "SELECT * FROM subscriptions WHERE id=?", (sub_id,)
    ).fetchone()
    conn.close()

    if not row:
        return RedirectResponse("/admin", status_code=303)

    return templates.TemplateResponse("edit.html", {"request": request, "sub": row})


@app.post("/admin/update", include_in_schema=False)
def admin_update(
    request: Request,
    sub_id: int = Form(...),
    name: str = Form(...),
    content: str = Form(...),
):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    now = int(time.time())
    conn = db()
    conn.execute(
        "UPDATE subscriptions SET name=?, content=?, updated_at=? WHERE id=?",
        (name.strip(), content, now, sub_id),
    )
    conn.commit()
    conn.close()
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/toggle", include_in_schema=False)
def admin_toggle(request: Request, sub_id: int = Form(...)):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    conn = db()
    row = conn.execute("SELECT is_active FROM subscriptions WHERE id=?", (sub_id,)).fetchone()
    if row:
        new_val = 0 if int(row["is_active"]) == 1 else 1
        conn.execute(
            "UPDATE subscriptions SET is_active=?, updated_at=? WHERE id=?",
            (new_val, int(time.time()), sub_id),
        )
        conn.commit()
    conn.close()
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/delete", include_in_schema=False)
def admin_delete(request: Request, sub_id: int = Form(...)):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    conn = db()
    conn.execute("DELETE FROM subscriptions WHERE id=?", (sub_id,))
    conn.commit()
    conn.close()
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/rotate", include_in_schema=False)
def admin_rotate(request: Request, sub_id: int = Form(...)):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    new_token = secrets.token_urlsafe(24)
    conn = db()
    conn.execute(
        "UPDATE subscriptions SET token=?, updated_at=? WHERE id=?",
        (new_token, int(time.time()), sub_id),
    )
    conn.commit()
    conn.close()
    return RedirectResponse("/admin", status_code=303)


from fastapi import Response

@app.get("/s/{token}", include_in_schema=False)
def serve_subscription(token: str, b64: int = 1):
    conn = db()
    row = conn.execute(
        "SELECT content, is_active FROM subscriptions WHERE token=?", (token,)
    ).fetchone()
    conn.close()

    if not row:
        return Response("Not found", status_code=404)

    if int(row["is_active"]) != 1:
        return Response("Disabled", status_code=410)

    content = row["content"].replace("\r\n", "\n").strip() + "\n"

    # اگر b64=1 (پیش‌فرض) => خروجی base64
    if b64 == 1:
        payload = base64.b64encode(content.encode("utf-8")).decode("ascii")
        return Response(
            payload,
            media_type="text/plain; charset=utf-8",
            headers={
                "Cache-Control": "no-store",
                "Content-Disposition": 'inline; filename="subscription.txt"',
            },
        )

    # اگر b64=0 => خروجی خام
    return Response(
        content,
        media_type="text/plain; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )
PYAPP

cat > /opt/subpanel/requirements.txt <<'REQ'
fastapi==0.115.0
uvicorn==0.30.6
jinja2==3.1.4
python-multipart==0.0.9
itsdangerous==2.2.0
REQ

cat > /opt/subpanel/static/style.css <<'CSS'
@import url('https://fonts.googleapis.com/css2?family=Vazirmatn:wght@300;400;500;600;700&display=swap');

:root{
  --bg:#f7f8fb;
  --card:#ffffff;
  --text:#111827;
  --muted:#6b7280;
  --border:#e5e7eb;
  --primary:#2563eb;
  --primary-2:#1d4ed8;
  --danger:#dc2626;
  --danger-2:#b91c1c;
  --ok:#16a34a;
  --warn:#f59e0b;

  --radius:16px;
  --shadow:0 8px 30px rgba(17,24,39,.08);
}

*{box-sizing:border-box}
html,body{height:100%}
body{
  margin:0;
  font-family: "Vazirmatn", system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif;
  background: var(--bg);
  color: var(--text);
  direction: rtl;
}

.container{
  max-width: 1100px;
  margin: 28px auto;
  padding: 0 14px;
}

.topbar{
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:12px;
  flex-wrap:wrap;
  margin-bottom: 18px;
}
.title{
  font-size: 22px;
  font-weight: 700;
  margin:0;
}
.subtle{
  color: var(--muted);
  font-size: 14px;
}

.grid{
  display:grid;
  grid-template-columns: 1fr;
  gap:14px;
}

.card{
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  padding: 16px;
}

.card h3{
  margin:0 0 10px 0;
  font-size: 16px;
  font-weight: 700;
}

hr.sep{
  border:0;
  border-top: 1px solid var(--border);
  margin: 14px 0;
}

.btn{
  display:inline-flex;
  align-items:center;
  justify-content:center;
  gap:8px;
  padding: 10px 12px;
  border-radius: 12px;
  border: 1px solid var(--border);
  background: #fff;
  color: var(--text);
  cursor:pointer;
  text-decoration:none;
  font-weight: 600;
  font-size: 14px;
  transition: transform .05s ease, border-color .15s ease, background .15s ease;
  user-select:none;
}
.btn:active{ transform: translateY(1px); }
.btn:hover{ border-color: #cbd5e1; background:#fafafa; }

.btn-primary{
  background: var(--primary);
  border-color: var(--primary);
  color:#fff;
}
.btn-primary:hover{ background: var(--primary-2); border-color: var(--primary-2); }

.btn-danger{
  background: #fff;
  border-color: #fecaca;
  color: var(--danger);
}
.btn-danger:hover{ background:#fff5f5; border-color:#fca5a5; }

.btn-ghost{
  background: transparent;
}

.badge{
  display:inline-flex;
  align-items:center;
  padding: 4px 10px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 700;
  border: 1px solid var(--border);
  background: #fff;
}
.badge-ok{ color: var(--ok); border-color: #bbf7d0; background:#f0fdf4; }
.badge-off{ color: var(--danger); border-color: #fecaca; background:#fff1f2; }

.input, .textarea{
  width:100%;
  padding: 12px 12px;
  border-radius: 14px;
  border: 1px solid var(--border);
  background:#fff;
  font-family: inherit;
  font-size: 14px;
  outline: none;
}
.input:focus, .textarea:focus{
  border-color: #93c5fd;
  box-shadow: 0 0 0 4px rgba(37, 99, 235, .12);
}
.textarea{ min-height: 320px; resize: vertical; line-height: 1.9; }

.row{
  display:flex;
  gap:10px;
  flex-wrap:wrap;
  align-items:center;
}

.table-wrap{
  overflow:auto;
  border: 1px solid var(--border);
  border-radius: 14px;
}
table{
  width:100%;
  border-collapse: collapse;
  min-width: 860px;
  background:#fff;
}
th, td{
  padding: 12px 12px;
  border-bottom: 1px solid var(--border);
  text-align: right;
  vertical-align: top;
  font-size: 14px;
}
th{
  background: #f9fafb;
  font-weight: 800;
}
tr:last-child td{ border-bottom:0; }

.code{
  display:block;
  background:#0b1220;
  color:#e5e7eb;
  padding:10px 12px;
  border-radius: 12px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 12px;
  line-height: 1.6;
  direction:ltr;
  word-break: break-all;
}

.actions{
  display:flex;
  gap:8px;
  flex-wrap:wrap;
}

.toast{
  position: fixed;
  bottom: 18px;
  right: 18px;
  background: #111827;
  color:#fff;
  padding: 10px 12px;
  border-radius: 12px;
  box-shadow: var(--shadow);
  opacity: 0;
  transform: translateY(10px);
  transition: .18s ease;
  pointer-events:none;
  font-size: 13px;
}
.toast.show{
  opacity: 1;
  transform: translateY(0);
}
input { direction: rtl; }
input[type="password"] { direction: ltr; text-align: left; }
/* لینک‌ها داخل دکمه مثل دکمه دیده شوند */
a.btn, a.btn:visited {
  color: inherit;
}

/* از underline جلوگیری شود */
a.btn { text-decoration: none; }

/* مطمئن شو همه دکمه‌ها و لینک‌های btn فونت واحد دارند */
.btn, button.btn, a.btn, input.btn {
  font-family: inherit !important;
}
/* URL compact row */
.urlbox{
  display:flex;
  align-items:center;
  gap:10px;
  background:#0b1220;
  color:#e5e7eb;
  border-radius: 12px;
  padding: 10px 12px;
}

.urltag{
  font-size: 12px;
  font-weight: 800;
  padding: 3px 10px;
  border-radius: 999px;
  background: rgba(255,255,255,.08);
  flex: 0 0 auto;
}

.urltext{
  flex: 1 1 auto;
  min-width: 0;
  direction: ltr;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  font-size: 12px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.copyicon{
  flex: 0 0 auto;
  width: 34px;
  height: 34px;
  border-radius: 10px;
  border: 1px solid rgba(255,255,255,.15);
  background: rgba(255,255,255,.06);
  color: #e5e7eb;
  cursor:pointer;
  display:inline-flex;
  align-items:center;
  justify-content:center;
  transition: .15s ease;
}
.copyicon:hover{
  background: rgba(255,255,255,.12);
  border-color: rgba(255,255,255,.25);
}
.copyicon:active{ transform: translateY(1px); }
/* همه input ها RTL و راست‌چین */
.input{
  direction: rtl;
  text-align: right;
}

/* پسورد: متن تایپ‌شده LTR ولی جایگاه و placeholder راست‌چین */
input[type="password"].input{
  direction: ltr;
  text-align: right;
}

/* placeholder ها همیشه راست‌چین */
.input::placeholder{
  direction: rtl;
  text-align: right;
}
CSS

cat > /opt/subpanel/templates/login.html <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8" />
  <title>ورود</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="container" style="max-width:520px">
    <div class="card">
      <div class="topbar" style="margin-bottom:10px">
        <h1 class="title" style="font-size:18px;margin:0">ورود ادمین</h1>
        <span class="subtle">پنل مدیریت</span>
      </div>

      {% if err %}
        <div class="card" style="border-color:#fecaca;background:#fff1f2;box-shadow:none">
          <b style="color:#b91c1c">خطا:</b> {{err}}
        </div>
        <div style="height:10px"></div>
      {% endif %}

      <form method="post" action="/login">
        <input class="input" name="username" placeholder="نام کاربری" required />
        <input class="input" name="password" type="password" placeholder="رمز عبور" required />
        <button class="btn btn-primary" type="submit" style="width:100%">ورود</button>
      </form>

      <div class="subtle" style="margin-top:10px">
        برای امنیت، از پسورد قوی استفاده کن.
      </div>
    </div>
  </div>
</body>
</html>
HTML

cat > /opt/subpanel/templates/admin.html <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8" />
  <title>پنل</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="container">

    <div class="topbar">
      <div>
        <h1 class="title">پنل مدیریت سابسکریپشن‌ها</h1>
        <div class="subtle">ایجاد، ویرایش، غیرفعال‌سازی و مدیریت لینک‌ها</div>
      </div>

      <form method="post" action="/logout">
        <button class="btn btn-ghost" type="submit">خروج</button>
      </form>
    </div>

    <div class="grid">
      <div class="card">
        <h3>ایجاد لینک سابسکریپشن</h3>
        <div class="row">
          <a class="btn btn-primary" href="/admin/new">ایجاد جدید</a>
          <span class="subtle">نام + متن کانفیگ‌ها را paste کن</span>
        </div>
      </div>

      <div class="card">
        <div class="row" style="justify-content:space-between">
          <h3 style="margin:0">لیست لینک‌های سابسکریپشن</h3>
          <span class="subtle">{{ subs|length }} مورد</span>
        </div>

        <hr class="sep">

        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th style="min-width:180px">نام</th>
                <th style="min-width:120px">وضعیت</th>
                <th>URL</th>
                <th style="min-width:360px">عملیات</th>
              </tr>
            </thead>
            <tbody>
              {% for s in subs %}
              {% set url = base_url ~ '/s/' ~ s['token'] %}
              <tr>
                <td><b>{{s["name"]}}</b></td>
                <td>
                  {% if s["is_active"] == 1 %}
                    <span class="badge badge-ok">فعال</span>
                  {% else %}
                    <span class="badge badge-off">غیرفعال</span>
                  {% endif %}
                </td>
		<td>
		  {% set url_b64 = base_url ~ '/s/' ~ s['token'] %}
		  {% set url_raw = base_url ~ '/s/' ~ s['token'] ~ '?b64=0' %}

		  <div class="urlbox">
		    <span class="urltag">b64</span>
		    <span class="urltext" id="urlb64-{{s['id']}}">{{url_b64}}</span>
		    <button class="copyicon" type="button" title="کپی لینک" onclick="copyById('urlb64-{{s['id']}}')">
		      <!-- copy icon -->
		      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
		        <path d="M9 9h10v10H9V9Z" stroke="currentColor" stroke-width="2" />
		        <path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1" stroke="currentColor" stroke-width="2"/>
		      </svg>
		    </button>
		  </div>

		  <div style="height:10px"></div>

		  <div class="urlbox">
		    <span class="urltag">raw</span>
		    <span class="urltext" id="urlraw-{{s['id']}}">{{url_raw}}</span>
		    <button class="copyicon" type="button" title="کپی لینک" onclick="copyById('urlraw-{{s['id']}}')">
		      <!-- copy icon -->
		      <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
		        <path d="M9 9h10v10H9V9Z" stroke="currentColor" stroke-width="2" />
		        <path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1" stroke="currentColor" stroke-width="2"/>
		      </svg>
		    </button>
		  </div>
		</td>
                <td>
                  <div class="actions">
                    <a class="btn" href="/admin/edit/{{s['id']}}">ويرايش</a>

                    <form method="post" action="/admin/toggle">
                      <input type="hidden" name="sub_id" value="{{s['id']}}">
                      <button class="btn" type="submit">
                        {% if s["is_active"] == 1 %}غیرفعال‌سازی{% else %}فعالسازي{% endif %}
                      </button>
                    </form>

                    <form method="post" action="/admin/rotate" onsubmit="return confirm('لینک تغییر کند؟ لینک قبلی از کار می‌افتد.');">
                      <input type="hidden" name="sub_id" value="{{s['id']}}">
                      <button class="btn" type="submit">تعویض URL</button>
                    </form>

                    <form method="post" action="/admin/delete" onsubmit="return confirm('حذف شود؟');">
                      <input type="hidden" name="sub_id" value="{{s['id']}}">
                      <button class="btn btn-danger" type="submit">حذف</button>
                    </form>
                  </div>
                </td>
              </tr>
              {% endfor %}
              {% if subs|length == 0 %}
              <tr><td colspan="4" class="subtle">هنوز چیزی ساخته نشده.</td></tr>
              {% endif %}
            </tbody>
          </table>
        </div>
      </div>
    </div>

  </div>

  <div id="toast" class="toast">کپی شد ✅</div>
<script>
  function showToast(msg){
    const t = document.getElementById('toast');
    t.textContent = msg || 'کپی شد ✅';
    t.classList.add('show');
    setTimeout(()=>t.classList.remove('show'), 1200);
  }

  async function copyById(elementId){
    const el = document.getElementById(elementId);
    const text = el.innerText.trim();
    try {
      await navigator.clipboard.writeText(text);
      showToast('کپی شد ✅');
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      showToast('کپی شد ✅');
    }
  }
</script>

</body>
</html>
HTML

cat > /opt/subpanel/templates/new.html <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8" />
  <title>ایجاد</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="container" style="max-width:980px">
    <div class="topbar">
      <div>
        <h1 class="title">ایجاد سابسکریپشن</h1>
        <div class="subtle">نام و متن کانفیگ‌ها را وارد کن</div>
      </div>
      <a class="btn btn-ghost" href="/admin">بازگشت</a>
    </div>

    <div class="card">
      <form method="post" action="/admin/create">
        <label class="subtle">نام</label>
        <input class="input" name="name" placeholder="مثلاً: سرور اصلی" required />

        <div style="height:8px"></div>
        <label class="subtle">متن کانفیگ‌ها</label>
        <textarea class="textarea" name="content" placeholder="هر چی لازم داری اینجا paste کن..." required></textarea>

        <div class="row" style="justify-content:flex-start;margin-top:10px">
          <button class="btn btn-primary" type="submit">ذخیره</button>
          <a class="btn" href="/admin">انصراف</a>
        </div>
      </form>
    </div>
  </div>
</body>
</html>
HTML

cat > /opt/subpanel/templates/edit.html <<'HTML'
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8" />
  <title>ادیت</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="container" style="max-width:980px">
    <div class="topbar">
      <div>
        <h1 class="title">ادیت سابسکریپشن</h1>
        <div class="subtle">تغییرات را اعمال کن و ذخیره بزن</div>
      </div>
      <a class="btn btn-ghost" href="/admin">بازگشت</a>
    </div>

    <div class="card">
      <form method="post" action="/admin/update">
        <input type="hidden" name="sub_id" value="{{sub['id']}}" />

        <label class="subtle">نام</label>
        <input class="input" name="name" value="{{sub['name']}}" required />

        <div style="height:8px"></div>
        <label class="subtle">متن کانفیگ‌ها</label>
        <textarea class="textarea" name="content" required>{{sub["content"]}}</textarea>

        <div class="row" style="justify-content:flex-start;margin-top:10px">
          <button class="btn btn-primary" type="submit">ذخیره</button>
          <a class="btn" href="/admin">انصراف</a>
        </div>
      </form>
    </div>
  </div>
</body>
</html>
HTML

echo "[+] Setting up venv..."
python3 -m venv /opt/subpanel/.venv
/opt/subpanel/.venv/bin/pip install --upgrade pip >/dev/null
/opt/subpanel/.venv/bin/pip install -r /opt/subpanel/requirements.txt >/dev/null

echo "[+] Writing env file (NOT committed to git)..."
cat > /etc/subpanel.env <<EOF
DB_PATH=/opt/subpanel/db.sqlite3
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
SECRET_KEY=${SECRET_KEY}
EOF
chmod 600 /etc/subpanel.env
chown root:root /etc/subpanel.env

echo "[+] Creating systemd service..."
cat > /etc/systemd/system/subpanel.service <<EOF
[Unit]
Description=SubPanel (FastAPI/Uvicorn)
After=network.target

[Service]
WorkingDirectory=/opt/subpanel
EnvironmentFile=/etc/subpanel.env
ExecStart=/opt/subpanel/.venv/bin/uvicorn app:app --host 127.0.0.1 --port ${APP_PORT}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subpanel
systemctl restart subpanel

echo "[+] Ensuring nginx rate-limit zone config..."
cat > /etc/nginx/conf.d/subpanel_rate_limit.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=login_zone:10m rate=10r/m;
EOF

echo "[+] Writing nginx site config (HTTP first for certbot)..."
cat > /etc/nginx/sites-available/subpanel <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 5m;

    location /static/ {
        alias /opt/subpanel/static/;
        expires 7d;
        add_header Cache-Control "public";
    }

    location = /login {
        limit_req zone=login_zone burst=5 nodelay;

        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location ^~ /admin {
        limit_req zone=login_zone burst=20 nodelay;

        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/subpanel /etc/nginx/sites-enabled/subpanel
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl reload nginx

echo "[+] Getting TLS certificate (certbot --nginx)..."
certbot --nginx -d "${DOMAIN}" --agree-tos --non-interactive --register-unsafely-without-email

systemctl reload nginx

echo
echo "[✓] نصب کامل شد!"
echo "Login: https://${DOMAIN}/login"
echo "Admin: https://${DOMAIN}/admin"
echo
echo "Env: /etc/subpanel.env (chmod 600)"
echo "Service: systemctl status subpanel --no-pager"
