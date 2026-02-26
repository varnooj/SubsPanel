import base64
import os
import sqlite3
import time
import secrets
import io
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import hashlib
import hmac
import base64 as b64lib

from fastapi import FastAPI, Request, Form, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from itsdangerous import URLSafeSerializer, BadSignature

APP_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.getenv("DB_PATH", os.path.join(APP_DIR, "db.sqlite3"))

# These env vars are used ONLY for the first-time seed (if admin table is empty)
ADMIN_USER_ENV = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS_ENV = os.getenv("ADMIN_PASS", "change-me-strong")

SECRET_KEY = os.getenv("SECRET_KEY", secrets.token_hex(32))
serializer = URLSafeSerializer(SECRET_KEY, salt="session-v1")

app = FastAPI()
templates = Jinja2Templates(directory=os.path.join(APP_DIR, "templates"))

# ===== Login Logger =====
LOG_DIR = Path(os.getenv("LOG_DIR", "/var/log/subpanel"))
LOG_FILE = LOG_DIR / "login.log"

def setup_login_logger() -> logging.Logger:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("subpanel.login")
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=5, encoding="utf-8")
        fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    return logger

login_logger = setup_login_logger()

def get_client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    xri = request.headers.get("x-real-ip")
    if xri:
        return xri.strip()
    if request.client:
        return request.client.host
    return "unknown"

def log_login_attempt(request: Request, username: str, ok: bool) -> None:
    ip = get_client_ip(request)
    ua = request.headers.get("user-agent", "-")
    host = request.headers.get("host", "-")
    result = "SUCCESS" if ok else "FAIL"
    login_logger.info(f"{result} | user={username} | ip={ip} | host={host} | ua={ua}")

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

# ===== Admin credentials (DB-based, hashed) =====
PBKDF2_ITERS = int(os.getenv("PBKDF2_ITERS", "200000"))

def _hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERS)

def _b64e(b: bytes) -> str:
    return b64lib.b64encode(b).decode("ascii")

def _b64d(s: str) -> bytes:
    return b64lib.b64decode(s.encode("ascii"))

def get_admin_row(conn: sqlite3.Connection):
    return conn.execute("SELECT username, pass_salt, pass_hash FROM admin_user WHERE id=1").fetchone()

def seed_admin_if_missing():
    conn = db()
    row = get_admin_row(conn)
    if row is None:
        salt = os.urandom(16)
        ph = _hash_password(ADMIN_PASS_ENV, salt)
        conn.execute(
            "INSERT INTO admin_user (id, username, pass_salt, pass_hash, updated_at) VALUES (1, ?, ?, ?, ?)",
            (ADMIN_USER_ENV, _b64e(salt), _b64e(ph), int(time.time())),
        )
        conn.commit()
    conn.close()

def get_admin_username() -> str:
    conn = db()
    row = get_admin_row(conn)
    conn.close()
    return row["username"] if row else ADMIN_USER_ENV

def verify_admin(username: str, password: str) -> bool:
    conn = db()
    row = get_admin_row(conn)
    conn.close()
    if not row:
        return (username == ADMIN_USER_ENV and password == ADMIN_PASS_ENV)

    if username != row["username"]:
        return False
    salt = _b64d(row["pass_salt"])
    expected = _b64d(row["pass_hash"])
    got = _hash_password(password, salt)
    return hmac.compare_digest(got, expected)

def update_admin_credentials(new_username: str, new_password: str | None):
    conn = db()
    row = get_admin_row(conn)
    if not row:
        # should not happen because we seed, but safe
        salt = os.urandom(16)
        ph = _hash_password(new_password or ADMIN_PASS_ENV, salt)
        conn.execute(
            "INSERT INTO admin_user (id, username, pass_salt, pass_hash, updated_at) VALUES (1, ?, ?, ?, ?)",
            (new_username, _b64e(salt), _b64e(ph), int(time.time())),
        )
        conn.commit()
        conn.close()
        return

    # keep old password if not changing
    salt = _b64d(row["pass_salt"])
    ph = _b64d(row["pass_hash"])
    if new_password is not None and new_password != "":
        salt = os.urandom(16)
        ph = _hash_password(new_password, salt)

    conn.execute(
        "UPDATE admin_user SET username=?, pass_salt=?, pass_hash=?, updated_at=? WHERE id=1",
        (new_username, _b64e(salt), _b64e(ph), int(time.time())),
    )
    conn.commit()
    conn.close()

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
        );
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS admin_user (
            id INTEGER PRIMARY KEY CHECK (id=1),
            username TEXT NOT NULL,
            pass_salt TEXT NOT NULL,
            pass_hash TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """
    )
    conn.commit()
    conn.close()

init_db()
seed_admin_if_missing()

def get_session_user(request: Request):
    cookie = request.cookies.get("session")
    if not cookie:
        return None
    try:
        data = serializer.loads(cookie)
        return data.get("u")
    except BadSignature:
        return None

def require_admin_or_redirect(request: Request):
    u = get_session_user(request)
    if u != get_admin_username():
        return RedirectResponse("/login", status_code=303)
    return None

def base_url(request: Request) -> str:
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.headers.get("host", request.url.netloc))
    return f"{proto}://{host}"

@app.get("/", include_in_schema=False)
def root(request: Request):
    u = get_session_user(request)
    if u == get_admin_username():
        return RedirectResponse("/admin", status_code=303)
    return RedirectResponse("/login", status_code=303)

@app.get("/login", response_class=HTMLResponse, include_in_schema=False)
def login_page(request: Request):
    return templates.TemplateResponse("login.html", {"request": request, "error": ""})

@app.post("/login", include_in_schema=False)
def do_login(request: Request, username: str = Form(...), password: str = Form(...)):
    ok_auth = verify_admin(username, password)
    log_login_attempt(request, username, ok_auth)

    if ok_auth:
        resp = RedirectResponse("/admin", status_code=303)
        token = serializer.dumps({"u": username, "t": int(time.time())})
        resp.set_cookie(
            "session",
            token,
            httponly=True,
            samesite="lax",
            secure=False,  # اگر همیشه HTTPS داری بهتره secure=True
        )
        return resp

    return templates.TemplateResponse(
        "login.html",
        {"request": request, "error": "نام کاربری یا رمز عبور اشتباه است"},
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
    subs = conn.execute("SELECT * FROM subscriptions ORDER BY id DESC").fetchall()
    conn.close()

    base = base_url(request)
    return templates.TemplateResponse(
        "admin.html",
        {
            "request": request,
            "subs": subs,
            "base_url": base,
        },
    )

# ===== Settings page =====
@app.get("/admin/settings", response_class=HTMLResponse, include_in_schema=False)
def admin_settings_page(request: Request):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir
    return templates.TemplateResponse(
        "settings.html",
        {"request": request, "error": "", "success": "", "current_user": get_admin_username()},
    )

@app.post("/admin/settings", response_class=HTMLResponse, include_in_schema=False)
def admin_settings_save(
    request: Request,
    current_password: str = Form(...),
    new_username: str = Form(""),
    new_password: str = Form(""),
    new_password2: str = Form(""),
):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    cur_user = get_admin_username()

    # Verify current password
    if not verify_admin(cur_user, current_password):
        return templates.TemplateResponse(
            "settings.html",
            {"request": request, "error": "رمز عبور فعلی اشتباه است", "success": "", "current_user": cur_user},
            status_code=400,
        )

    new_username = (new_username or "").strip() or cur_user

    # Validate password change (optional)
    change_pass = (new_password or "").strip() != ""
    if change_pass:
        if len(new_password) < 8:
            return templates.TemplateResponse(
                "settings.html",
                {"request": request, "error": "رمز جدید باید حداقل ۸ کاراکتر باشد", "success": "", "current_user": cur_user},
                status_code=400,
            )
        if new_password != new_password2:
            return templates.TemplateResponse(
                "settings.html",
                {"request": request, "error": "تکرار رمز جدید با رمز جدید یکسان نیست", "success": "", "current_user": cur_user},
                status_code=400,
            )

    # Must change something
    if (new_username == cur_user) and (not change_pass):
        return templates.TemplateResponse(
            "settings.html",
            {"request": request, "error": "هیچ تغییری اعمال نشده است", "success": "", "current_user": cur_user},
            status_code=400,
        )

    update_admin_credentials(new_username, new_password if change_pass else None)

    # Refresh session cookie with new username
    resp = RedirectResponse("/admin/settings", status_code=303)
    token = serializer.dumps({"u": new_username, "t": int(time.time())})
    resp.set_cookie(
        "session",
        token,
        httponly=True,
        samesite="lax",
        secure=False,
    )
    return resp

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
        "INSERT INTO subscriptions (name, token, content, is_active, created_at, updated_at) VALUES (?,?,?,?,?,?)",
        (name.strip(), token, content.strip(), 1, now, now),
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
    sub = conn.execute("SELECT * FROM subscriptions WHERE id=?", (sub_id,)).fetchone()
    conn.close()
    if not sub:
        return RedirectResponse("/admin", status_code=303)
    return templates.TemplateResponse("edit.html", {"request": request, "sub": sub})

@app.post("/admin/update", include_in_schema=False)
def admin_update(request: Request, sub_id: int = Form(...), name: str = Form(...), content: str = Form(...)):
    redir = require_admin_or_redirect(request)
    if redir:
        return redir

    conn = db()
    conn.execute(
        "UPDATE subscriptions SET name=?, content=?, updated_at=? WHERE id=?",
        (name.strip(), content.strip(), int(time.time()), sub_id),
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

@app.get("/qr", include_in_schema=False, response_class=Response)
def qr(url: str):
    import qrcode
    img = qrcode.make(url)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return Response(content=buf.getvalue(), media_type="image/png", headers={"Cache-Control": "no-store"})

@app.get("/s/{token}", include_in_schema=False)
def serve_subscription(token: str, b64: int = 1):
    conn = db()
    row = conn.execute("SELECT content, is_active FROM subscriptions WHERE token=?", (token,)).fetchone()
    conn.close()

    if not row:
        return Response("Not found", status_code=404)
    if int(row["is_active"]) != 1:
        return Response("Disabled", status_code=410)

    content = row["content"].replace("\r\n", "\n").strip() + "\n"

    if b64 == 1:
        payload = base64.b64encode(content.encode("utf-8")).decode("ascii")
        return Response(
            payload,
            media_type="text/plain; charset=utf-8",
            headers={"Cache-Control": "no-store", "Content-Disposition": 'inline; filename="subscription.txt"'},
        )

    return Response(content, media_type="text/plain; charset=utf-8", headers={"Cache-Control": "no-store"})