#!/usr/bin/env python3
"""noteapp.py：在 Mac 上讀寫 iPad 筆記軟體（v12.17.0 起）。只用 Python 內建的東西，不用裝套件。

iPad：首頁 → 設定 →「讓 Claude 連進來」打開，看配對碼。iPad 和 Mac 要在同一個 Wi-Fi，筆記軟體開在前景。

  python3 tools/noteapp.py pair 123456 [--host 192.168.1.23]   第一次：配對（找不到 iPad 時用 --host 手動給位址）
  python3 tools/noteapp.py ping                                 測試連線
  python3 tools/noteapp.py list                                 列出筆記本
  python3 tools/noteapp.py current                              iPad 現在開著哪一本、哪一頁、看得到的範圍
  python3 tools/noteapp.py show <筆記本> [--from 1 --to 5] [--no-texts]
  python3 tools/noteapp.py image <筆記本> [--page 3] [--x --y --w --h] [--width 1200] [-o 檔名.jpg]
  python3 tools/noteapp.py add <筆記本> <JSON 檔或 ->            加文字方塊（POST texts）
  python3 tools/noteapp.py pages <筆記本> <JSON 檔或 ->          加頁（POST pages）
  python3 tools/noteapp.py edit <筆記本> <方塊編號> <JSON 檔或 ->
  python3 tools/noteapp.py delete <筆記本> <方塊編號>
  python3 tools/noteapp.py outline <筆記本> <標題> [--page 3] [--parent 編號]
  python3 tools/noteapp.py new <名稱> [--board] [--folder 資料夾]
  python3 tools/noteapp.py batch <筆記本> <JSON 檔或 ->          一次加、改、移、刪很多個（一步上一步）
  python3 tools/noteapp.py measure <筆記本> [--page 3]           畫面上量到的實際大小（要開著）
  python3 tools/noteapp.py addimage <筆記本> <圖片檔> [--page 3 --x --y --width]
  python3 tools/noteapp.py search <字>                          所有筆記本找字
  python3 tools/noteapp.py open <筆記本> [--page 3] [--rect x,y,w,h]   iPad 打開、跳過去
  python3 tools/noteapp.py ocr <筆記本> [--page 3] [--x --y --w --h]   手寫變文字
  python3 tools/noteapp.py raw GET /notebooks                   直接呼叫 API

<筆記本> 可以是編號、完整名稱、名稱的一部分（只有一本符合時），或 current（iPad 現在開著的那本）。

add 的 JSON 範例（座標是頁面座標；A4 頁 595×842，白板是一整張大頁面；size 跟文字工具列上的數字一樣）：
  {"page": 3,                           # 省略或 "current"＝畫面上那頁；"last"＝最後一頁；白板不用寫
   "boxes": [
     {"key": "a", "text": "標題", "size": 24, "bold": true, "frame": "none"},
     {"key": "b", "text": "$E=mc^2$", "frame": "#73B8FF"},          # frame: none / blue / default / #RRGGBB / {color, mode, shape}
     {"key": "c", "text": "說明", "x": 300, "y": 200, "width": 240, "color": "#FFFFFF"}
   ],
   "links": [{"from": "a", "to": "b"}, {"from": "b", "to": "c", "route": "curve", "arrow": "none"}]}
沒寫 x、y 的方塊自動往下排：筆記本接在這頁最下面的東西下面；白板從畫面看得到的左上角開始。

設定（位址、鑰匙）存在 ~/.config/noteapp/config.json（只有自己讀得到），不要放進 repo。
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONFIG = os.path.expanduser("~/.config/noteapp/config.json")
SERVICE = "_noteapp._tcp"
DEFAULT_PORT = 8765


def load_config():
    try:
        with open(CONFIG, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    fd = os.open(CONFIG, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.chmod(CONFIG, 0o600)


def run_for(cmd, seconds):
    """跑一個不會自己結束的指令（dns-sd），幾秒後停掉，拿它印出來的東西"""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    except OSError:
        return ""
    time.sleep(seconds)
    p.terminate()
    try:
        out, _ = p.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        p.kill()
        out, _ = p.communicate()
    return out or ""


def discover():
    """用 Bonjour 找 iPad 上的筆記軟體，回傳 (位址, 埠)；找不到回傳 None"""
    browse = run_for(["dns-sd", "-B", SERVICE, "local."], 2.5)
    names = []
    for line in browse.splitlines():
        m = re.search(r"\s+Add\s+\d+\s+\d+\s+\S+\s+" + re.escape(SERVICE) + r"\.\s+(.+)$", line)
        if m and m.group(1).strip() not in names:
            names.append(m.group(1).strip())
    for name in names:
        info = run_for(["dns-sd", "-L", name, SERVICE, "local."], 2.0)
        m = re.search(r"can be reached at (\S+?)\.?:(\d+)", info)
        if not m:
            continue
        host, port = m.group(1), int(m.group(2))
        try:
            addr = socket.gethostbyname(host)
        except OSError:
            addr = host
        return addr, port
    return None


def base_url(cfg):
    return "http://%s:%d" % (cfg["host"], cfg.get("port", DEFAULT_PORT))


def request(cfg, method, path, body=None, raw=False, timeout=45):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if cfg.get("token"):
        headers["Authorization"] = "Bearer " + cfg["token"]
    req = urllib.request.Request(base_url(cfg) + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            content = r.read()
            return r.status, content if raw else json.loads(content.decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        content = e.read()
        try:
            return e.code, json.loads(content.decode("utf-8"))
        except ValueError:
            return e.code, {"error": content.decode("utf-8", "replace")}


def call(method, path, body=None, raw=False):
    """呼叫 API；連不上就重新找一次 iPad（Wi-Fi 位址可能換了）"""
    cfg = load_config()
    if not cfg.get("token"):
        sys.exit("還沒配對：python3 tools/noteapp.py pair <iPad 上的配對碼>")
    try:
        return request(cfg, method, path, body, raw)
    except (urllib.error.URLError, OSError, socket.timeout) as e:
        reason = getattr(e, "reason", e)
        if isinstance(e, TimeoutError) or isinstance(reason, TimeoutError):
            # 連上了但太久沒回（大白板畫圖、辨識比較慢）：不要重送，免得做兩次
            sys.exit("iPad 太久沒回應（超過 45 秒）：可能還在處理，等一下用 current／show 確認結果，不要直接重送")
        found = discover()
        if not found:
            sys.exit("連不到 iPad：筆記軟體要開在前景、「讓 Claude 連進來」打開、跟 Mac 在同一個 Wi-Fi。")
        cfg["host"], cfg["port"] = found
        save_config(cfg)
        try:
            return request(cfg, method, path, body, raw)
        except (urllib.error.URLError, OSError, socket.timeout) as e:
            sys.exit("連不到 iPad（%s:%d）：%s" % (cfg["host"], cfg["port"], e))


def nb(key):
    return urllib.parse.quote(key, safe="")


def read_json(arg):
    text = sys.stdin.read() if arg == "-" else open(arg, encoding="utf-8").read()
    return json.loads(text)


def out(status, data):
    print(json.dumps(data, ensure_ascii=False, indent=1))
    if status != 200:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description="在 Mac 上讀寫 iPad 筆記軟體")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pair"); p.add_argument("code"); p.add_argument("--host")
    sub.add_parser("ping"); sub.add_parser("list"); sub.add_parser("current")
    p = sub.add_parser("show"); p.add_argument("notebook"); p.add_argument("--from", dest="frm", type=int)
    p.add_argument("--to", type=int); p.add_argument("--no-texts", action="store_true")
    p = sub.add_parser("image"); p.add_argument("notebook"); p.add_argument("--page")
    for k in ("x", "y", "w", "h"):
        p.add_argument("--" + k, type=float)
    p.add_argument("--width", type=int); p.add_argument("-o", "--output")
    p = sub.add_parser("add"); p.add_argument("notebook"); p.add_argument("json")
    p = sub.add_parser("pages"); p.add_argument("notebook"); p.add_argument("json")
    p = sub.add_parser("edit"); p.add_argument("notebook"); p.add_argument("box"); p.add_argument("json")
    p = sub.add_parser("delete"); p.add_argument("notebook"); p.add_argument("box")
    p = sub.add_parser("outline"); p.add_argument("notebook"); p.add_argument("title")
    p.add_argument("--page"); p.add_argument("--parent")
    p = sub.add_parser("new"); p.add_argument("title"); p.add_argument("--board", action="store_true")
    p.add_argument("--folder")
    p = sub.add_parser("batch"); p.add_argument("notebook"); p.add_argument("json")
    p = sub.add_parser("measure"); p.add_argument("notebook"); p.add_argument("--page")
    p = sub.add_parser("addimage"); p.add_argument("notebook"); p.add_argument("file"); p.add_argument("--page")
    for k in ("x", "y", "width", "height"):
        p.add_argument("--" + k, type=float)
    p = sub.add_parser("search"); p.add_argument("q"); p.add_argument("--limit", type=int)
    p = sub.add_parser("open"); p.add_argument("notebook"); p.add_argument("--page"); p.add_argument("--rect")
    p = sub.add_parser("ocr"); p.add_argument("notebook"); p.add_argument("--page")
    for k in ("x", "y", "w", "h"):
        p.add_argument("--" + k, type=float)
    p = sub.add_parser("raw"); p.add_argument("method"); p.add_argument("path"); p.add_argument("json", nargs="?")
    a = ap.parse_args()

    if a.cmd == "pair":
        if a.host:
            host, _, port = a.host.partition(":")
            found = (host, int(port) if port else DEFAULT_PORT)
        else:
            found = discover()
            if not found:
                sys.exit("找不到 iPad：確認筆記軟體開著、「讓 Claude 連進來」打開；或用 --host 給 iPad 設定畫面上的位址")
        cfg = {"host": found[0], "port": found[1]}
        try:
            status, data = request(cfg, "POST", "/pair", {"code": a.code})
        except (urllib.error.URLError, OSError, socket.timeout) as e:
            sys.exit("連不到 %s:%d：%s" % (found[0], found[1], e))
        if status != 200 or not data.get("token"):
            out(status, data)
        cfg["token"] = data["token"]
        save_config(cfg)
        print("配對成功：%s:%d" % found)
        return

    if a.cmd == "ping":
        out(*call("GET", "/ping"))
    elif a.cmd == "list":
        status, data = call("GET", "/notebooks")
        if status != 200:
            out(status, data)
        for n in data.get("notebooks", []):
            kind = "白板" if n.get("board") else "筆記"
            where = n.get("folder") or "（最外層）"
            if n.get("inBoard"):
                where += "／白板「%s」裡" % n["inBoard"]
            print("%s  %s  %-24s %s%s" % (n["id"], kind, n["title"], where, "  ●開著" if n.get("open") else ""))
    elif a.cmd == "current":
        out(*call("GET", "/current"))
    elif a.cmd == "show":
        q = {}
        if a.frm: q["from"] = a.frm
        if a.to: q["to"] = a.to
        if a.no_texts: q["texts"] = 0
        out(*call("GET", "/notebooks/%s?%s" % (nb(a.notebook), urllib.parse.urlencode(q))))
    elif a.cmd == "image":
        q = {}
        if a.page: q["page"] = a.page
        for k in ("x", "y", "w", "h", "width"):
            v = getattr(a, k)
            if v is not None: q[k] = v
        status, data = call("GET", "/notebooks/%s/image?%s" % (nb(a.notebook), urllib.parse.urlencode(q)), raw=True)
        if status != 200:
            out(status, data)
        path = a.output or "/tmp/noteapp-page.jpg"
        with open(path, "wb") as f:
            f.write(data)
        print(path)
    elif a.cmd == "add":
        out(*call("POST", "/notebooks/%s/texts" % nb(a.notebook), read_json(a.json)))
    elif a.cmd == "pages":
        out(*call("POST", "/notebooks/%s/pages" % nb(a.notebook), read_json(a.json)))
    elif a.cmd == "edit":
        out(*call("PATCH", "/notebooks/%s/texts/%s" % (nb(a.notebook), a.box), read_json(a.json)))
    elif a.cmd == "delete":
        out(*call("DELETE", "/notebooks/%s/texts/%s" % (nb(a.notebook), a.box)))
    elif a.cmd == "outline":
        body = {"title": a.title}
        if a.page: body["page"] = int(a.page) if a.page.isdigit() else a.page
        if a.parent: body["parent"] = a.parent
        out(*call("POST", "/notebooks/%s/outline" % nb(a.notebook), body))
    elif a.cmd == "new":
        body = {"title": a.title, "board": a.board}
        if a.folder: body["folder"] = a.folder
        out(*call("POST", "/notebooks", body))
    elif a.cmd == "batch":
        out(*call("POST", "/notebooks/%s/batch" % nb(a.notebook), read_json(a.json)))
    elif a.cmd == "measure":
        q = {"page": a.page} if a.page else {}
        out(*call("GET", "/notebooks/%s/measure?%s" % (nb(a.notebook), urllib.parse.urlencode(q))))
    elif a.cmd == "addimage":
        import base64
        with open(a.file, "rb") as f:
            body = {"data": base64.b64encode(f.read()).decode("ascii")}
        if a.page: body["page"] = int(a.page) if a.page.isdigit() else a.page
        for k in ("x", "y", "width", "height"):
            v = getattr(a, k)
            if v is not None: body[k] = v
        out(*call("POST", "/notebooks/%s/images" % nb(a.notebook), body))
    elif a.cmd == "search":
        q = {"q": a.q}
        if a.limit: q["limit"] = a.limit
        out(*call("GET", "/search?%s" % urllib.parse.urlencode(q)))
    elif a.cmd == "open":
        body = {"notebook": a.notebook}
        if a.page: body["page"] = int(a.page) if a.page.isdigit() else a.page
        if a.rect:
            x, y, w, h = [float(v) for v in a.rect.split(",")]
            body["rect"] = {"x": x, "y": y, "w": w, "h": h}
        out(*call("POST", "/open", body))
    elif a.cmd == "ocr":
        q = {}
        if a.page: q["page"] = a.page
        for k in ("x", "y", "w", "h"):
            v = getattr(a, k)
            if v is not None: q[k] = v
        out(*call("GET", "/notebooks/%s/ocr?%s" % (nb(a.notebook), urllib.parse.urlencode(q))))
    elif a.cmd == "raw":
        body = read_json(a.json) if a.json else None
        out(*call(a.method.upper(), a.path, body))


if __name__ == "__main__":
    main()
