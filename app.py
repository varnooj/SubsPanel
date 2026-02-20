import base64
import os
import sqlite3
import time
import secrets
import io
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
        );
        """
    )
    conn.commit()
    conn.close()


init_db()


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
    if u != ADMIN_USER:
        return RedirectResponse("/login", status_code=303)
    return None


def base_url(request: Request) -> str:
    # Prefer X-Forwarded-* from Nginx (especially when using custom HTTPS port)
    proto = request.headers.get("x-forwarded-proto", request.url.scheme)
    host = request.headers.get("x-forwarded-host", request.headers.get("host", request.url.netloc))
    return f"{proto}://{host}"


@app.get("/", include_in_schema=False)
def root(request: Request):
    # redirect to admin or login
    u = get_session_user(request)
    if u == ADMIN_USER:
        return RedirectResponse("/admin", status_code=303)
    return RedirectResponse("/login", status_code=303)


@app.get("/login", response_class=HTMLResponse, include_in_schema=False)
def login_page(request: Request):
    return templates.TemplateResponse("login.html", {"request": request, "error": ""})


@app.post("/login", include_in_schema=False)
def do_login(request: Request, username: str = Form(...), password: str = Form(...)):
    if username == ADMIN_USER and password == ADMIN_PASS:
        resp = RedirectResponse("/admin", status_code=303)
        token = serializer.dumps({"u": username, "t": int(time.time())})
        resp.set_cookie(
            "session",
            token,
            httponly=True,
            samesite="lax",
            secure=False,  # Nginx TLS terminates; cookie secure still works but keep false for local testing
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


# --- QR code endpoint (server-side, no external JS) ---
@app.get("/qr", include_in_schema=False, response_class=Response)
def qr(url: str):
    """Return a PNG QR code for the given URL."""
    import qrcode
    img = qrcode.make(url)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return Response(
        content=buf.getvalue(),
        media_type="image/png",
        headers={"Cache-Control": "no-store"},
    )


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

    # b64=1 (default)
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

    # raw
    return Response(
        content,
        media_type="text/plain; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )
