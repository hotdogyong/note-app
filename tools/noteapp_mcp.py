#!/usr/bin/env python3
"""noteapp_mcp.py：iPad 筆記軟體的連接器（MCP 伺服器，stdio），讓 Mac 上 Claude 桌面 App 的一般聊天也能讀寫筆記。

只用 Python 內建的東西。連線、配對沿用 tools/noteapp.py（鑰匙在 ~/.config/noteapp/config.json；
還沒配對的話先在終端機跑 python3 tools/noteapp.py pair <配對碼>）。

登記在 ~/Library/Application Support/Claude/claude_desktop_config.json 的 mcpServers：
  "筆記軟體": {"command": "/usr/local/bin/python3", "args": ["<這個檔案的完整路徑>"]}
"""

import base64
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import noteapp  # noqa: E402

SERVER_NAME = "noteapp"
SERVER_VERSION = "1.1.0"

INSTRUCTIONS = """這個連接器可以讀寫使用者 iPad 上的筆記軟體（自己做的 App，用來準備研究所考試：物理、線性代數、工程數學）。
條件：iPad 上筆記軟體開在前景、設定裡「讓 Claude 連進來」打開、跟這台 Mac 在同一個網路。連不到時照錯誤訊息請使用者檢查，不要一直重試。

工作方式：
- 使用者說「我現在看的地方」「這頁」，先用 notes_current 看他開著哪一本、哪一頁、看得到的範圍（visible，頁面座標）。
- 加東西之前先用 notes_read 看那頁已經有哪些文字方塊（x、y、w、h），必要時用 notes_image 看那頁的圖（手寫筆跡只看得到圖）。放在空白的地方，不要蓋到手寫、課本的字、別的方塊。
- 座標是頁面座標：一般 A4 頁 595×842（左上角是 0,0）；白板是一整張很大的頁面，要放在 notes_current 的 visible 範圍裡。
- size 是字級，跟 App 工具列上的數字一樣（以 A4 為準，平常 16～24）。數學式用 $...$ 或 $$...$$（KaTeX）。
- frame：none（沒有框）、blue（淡紫藍圓角框）、default（使用者設的預設）、或 "#RRGGBB"（例如使用者喜歡的天藍 #73B8FF）。
- 加完之後看回傳的 w、h（measured＝true 是畫面上量到的實際大小，含排好的數學式），或用 notes_image 看一次排版；有疊到就調整。
- 一次動很多個方塊（整排往下移、改一堆字級、刪一批、加一組再連線）一律用 notes_batch，一次完成、使用者按一次上一步就全部還原；不要一個一個呼叫 notes_edit_text。
- 整區往下挪：notes_batch 的 move 給 rect（範圍裡的方塊和圖片一起動）和 dy。
- 使用者說「找我寫過的 XX」用 notes_search；要讓使用者看到某個地方用 notes_open（會跳過去，跳之前自動插旗子，使用者可以跳回來）。
- 手寫內容用 notes_ocr 讀成文字（數學式常認錯，要配合 notes_image 看）。
- 要放圖（例如畫好的圖表、示意圖）用 notes_add_image，給 Mac 上圖片檔的路徑。
- 刪除或修改使用者自己寫的方塊之前，一定要先問使用者。加頁在打開中的筆記本會清掉「上一步」的紀錄，要先跟使用者說。
- 跟使用者講話一律繁體中文（台灣用語）。"""

BOX_SCHEMA = {
    "type": "object",
    "properties": {
        "key": {"type": "string", "description": "自己取的代號，連線 links 用"},
        "text": {"type": "string", "description": "內容；數學式用 $...$"},
        "x": {"type": "number", "description": "左上角 x（頁面座標）；不給就自動往下排"},
        "y": {"type": "number"},
        "width": {"type": "number", "description": "固定寬度（會換行）；不給就照字的長度"},
        "size": {"type": "number", "description": "字級（以 A4 為準）"},
        "bold": {"type": "boolean"},
        "color": {"type": "string", "description": "字的顏色 #RRGGBB、white、black；不給照紙的深淺"},
        "frame": {"description": "none、blue、default、#RRGGBB，或 {color, mode: 0 填滿/1 外框＋上面一條/2 只有外框, shape: 0 方/1 圓角/2 圓頭}"},
        "align": {"type": "string", "enum": ["left", "center", "right"]},
        "markdown": {"type": "boolean", "description": "用 Markdown 排版（標題、條列、表格）"},
        "sticky": {"type": "boolean", "description": "做成黃色便利貼"},
    },
    "required": ["text"],
}

LINK_SCHEMA = {
    "type": "object",
    "properties": {
        "from": {"type": "string", "description": "方塊的 key 或已存在方塊的 id"},
        "to": {"type": "string"},
        "route": {"type": "string", "enum": ["elbow", "straight", "curve"]},
        "arrow": {"type": "string", "enum": ["end", "none", "both"]},
        "color": {"type": "string"},
        "dash": {"type": "boolean"},
    },
    "required": ["from", "to"],
}

NOTEBOOK = {"type": "string", "description": "筆記本的編號、完整名稱、名稱的一部分（只有一本符合時），或 current（iPad 現在開著的）"}
PAGE = {"description": "第幾頁（1 開始）、current（畫面上那頁）、last，或頁的 id；白板不用給"}

TOOLS = [
    {"name": "notes_list", "description": "列出所有筆記本和白板（編號、名稱、資料夾、有沒有開著）",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "notes_current", "description": "iPad 現在開著哪一本、第幾頁、畫面看得到的範圍（頁面座標）",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "notes_read", "description": "讀一本筆記：每頁的大小、紙張、文字方塊（內容、位置、大小、外框）、連線、圖片位置、大綱",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK,
         "from": {"type": "integer", "description": "從第幾頁"}, "to": {"type": "integer", "description": "到第幾頁"},
         "texts": {"type": "boolean", "description": "false＝只要頁的資訊、不要方塊內容（大本筆記先看概況用）"}},
         "required": ["notebook"]}},
    {"name": "notes_image", "description": "把一頁（或白板的一塊）畫成圖片回傳，用來看手寫、課本內容、排版",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": PAGE,
         "x": {"type": "number"}, "y": {"type": "number"}, "w": {"type": "number"}, "h": {"type": "number"},
         "width": {"type": "integer", "description": "圖片寬度（像素，預設 1000）"}},
         "required": ["notebook"]}},
    {"name": "notes_add_texts", "description": "在一頁上加文字方塊（可以一次加很多個、用線連起來）。打開中的筆記本使用者按一次「上一步」可以全部拿掉",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": PAGE,
         "boxes": {"type": "array", "items": BOX_SCHEMA},
         "links": {"type": "array", "items": LINK_SCHEMA},
         "x": {"type": "number", "description": "自動排的起點 x"}, "y": {"type": "number", "description": "自動排的起點 y"},
         "gap": {"type": "number", "description": "自動排時方塊之間的距離"}},
         "required": ["notebook", "boxes"]}},
    {"name": "notes_add_pages", "description": "在筆記本裡插入新的頁（可以順便放文字方塊）。白板不能加頁",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK,
         "after": {"description": "插在第幾頁後面（0＝最前面、last＝最後面；不給＝畫面上那頁後面）"},
         "count": {"type": "integer"},
         "paper": {"type": "string", "enum": ["dark", "white", "cream"]},
         "pages": {"type": "array", "items": {"type": "object", "properties": {
             "boxes": {"type": "array", "items": BOX_SCHEMA}, "links": {"type": "array", "items": LINK_SCHEMA}}}}},
         "required": ["notebook"]}},
    {"name": "notes_edit_text", "description": "改一個文字方塊：內容、位置、寬度、字級、顏色、外框（改使用者自己寫的之前先問）",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "box": {"type": "string", "description": "方塊的 id"},
         "text": {"type": "string"}, "x": {"type": "number"}, "y": {"type": "number"}, "width": {"type": "number"},
         "size": {"type": "number"}, "bold": {"type": "boolean"}, "color": {"type": "string"}, "frame": {}},
         "required": ["notebook", "box"]}},
    {"name": "notes_delete_text", "description": "刪一個文字方塊（連到它的線一起刪）。只在使用者明確要求時用",
     "inputSchema": {"type": "object", "properties": {"notebook": NOTEBOOK, "box": {"type": "string"}},
                     "required": ["notebook", "box"]}},
    {"name": "notes_add_outline", "description": "在大綱加一項（指到某一頁）",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "title": {"type": "string"}, "page": PAGE,
         "parent": {"type": "string", "description": "上一層那項的 id"}},
         "required": ["notebook", "title"]}},
    {"name": "notes_batch", "description": "同一頁一次做很多事（打開中的筆記本只算一步上一步）。順序：delete → deleteImages → update → move → unlink → add → links。整排移動、大量修改都用這個",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": dict(PAGE, description="哪一頁；不給就看 update／delete／move 提到的第一個方塊在哪頁"),
         "delete": {"type": "array", "items": {"type": "string"}, "description": "要刪的方塊 id（使用者同意才刪）"},
         "deleteImages": {"type": "array", "items": {"type": "string"}},
         "update": {"type": "array", "items": {"type": "object", "properties": {
             "id": {"type": "string"}, "text": {"type": "string"}, "x": {"type": "number"}, "y": {"type": "number"},
             "width": {"type": "number"}, "size": {"type": "number"}, "bold": {"type": "boolean"},
             "color": {"type": "string"}, "frame": {}, "align": {"type": "string"}}, "required": ["id"]}},
         "move": {"type": "object", "description": "ids 或 rect（中心點在範圍裡的方塊和圖片）一起平移 dx、dy", "properties": {
             "ids": {"type": "array", "items": {"type": "string"}},
             "rect": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "w": {"type": "number"}, "h": {"type": "number"}}},
             "dx": {"type": "number"}, "dy": {"type": "number"}}},
         "unlink": {"type": "array", "items": {"type": "string"}, "description": "要拿掉的連線 id"},
         "add": {"type": "array", "items": BOX_SCHEMA},
         "links": {"type": "array", "items": LINK_SCHEMA},
         "x": {"type": "number"}, "y": {"type": "number"}, "gap": {"type": "number"}},
         "required": ["notebook"]}},
    {"name": "notes_measure", "description": "量這頁每個方塊在畫面上的實際大小（含排好的數學式）。筆記本要開著",
     "inputSchema": {"type": "object", "properties": {"notebook": NOTEBOOK, "page": PAGE}, "required": ["notebook"]}},
    {"name": "notes_add_image", "description": "把 Mac 上的一張圖（PNG／JPEG）放進某一頁",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": PAGE, "path": {"type": "string", "description": "Mac 上圖片檔的完整路徑"},
         "x": {"type": "number"}, "y": {"type": "number"}, "width": {"type": "number"}, "height": {"type": "number"},
         "above": {"type": "boolean", "description": "true＝蓋在筆跡上面"}},
         "required": ["notebook", "path"]}},
    {"name": "notes_search", "description": "在所有筆記本的文字方塊、大綱、名稱裡找字（手寫和課本 PDF 的字找不到）",
     "inputSchema": {"type": "object", "properties": {"q": {"type": "string"}, "limit": {"type": "integer"}}, "required": ["q"]}},
    {"name": "notes_open", "description": "讓 iPad 打開某一本筆記，跳到某一頁、把某一塊捲進畫面（跳之前自動插旗子）",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": PAGE,
         "rect": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}, "w": {"type": "number"}, "h": {"type": "number"}}}},
         "required": ["notebook"]}},
    {"name": "notes_ocr", "description": "把一頁（或一塊）的手寫、課本文字辨識成文字（中英文；數學式常認錯）",
     "inputSchema": {"type": "object", "properties": {
         "notebook": NOTEBOOK, "page": PAGE,
         "x": {"type": "number"}, "y": {"type": "number"}, "w": {"type": "number"}, "h": {"type": "number"}},
         "required": ["notebook"]}},
    {"name": "notes_new_notebook", "description": "新增一本筆記本或白板",
     "inputSchema": {"type": "object", "properties": {
         "title": {"type": "string"}, "board": {"type": "boolean", "description": "true＝白板"},
         "folder": {"type": "string", "description": "資料夾名稱；不給＝最外層"}},
         "required": ["title"]}},
]


class ToolError(Exception):
    pass


def api(method, path, body=None, raw=False):
    """呼叫 iPad；noteapp.call 失敗時會 sys.exit，這裡接住變成錯誤訊息"""
    try:
        status, data = noteapp.call(method, path, body, raw=raw)
    except SystemExit as e:
        raise ToolError(str(e.code) if e.code else "連不到 iPad")
    if status != 200:
        msg = data.get("error") if isinstance(data, dict) else None
        raise ToolError(msg or ("iPad 回了錯誤 %s" % status))
    return data


def nb(args):
    key = args.get("notebook")
    if not key:
        raise ToolError("要給 notebook")
    return urllib.parse.quote(str(key), safe="")


def text_result(data):
    return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False, indent=1)}]}


def pick(args, keys):
    return {k: args[k] for k in keys if k in args and args[k] is not None}


def run_tool(name, args):
    if name == "notes_list":
        data = api("GET", "/notebooks")
        lines = []
        for n in data.get("notebooks", []):
            where = n.get("folder") or "最外層"
            if n.get("inBoard"):
                where += "／白板「%s」裡" % n["inBoard"]
            lines.append("%s｜%s｜%s｜%s%s" % (n["id"], "白板" if n.get("board") else "筆記本", n["title"], where,
                                            "｜開著" if n.get("open") else ""))
        return {"content": [{"type": "text", "text": "編號｜種類｜名稱｜位置\n" + "\n".join(lines)}]}
    if name == "notes_current":
        return text_result(api("GET", "/current"))
    if name == "notes_read":
        q = {}
        if args.get("from"): q["from"] = args["from"]
        if args.get("to"): q["to"] = args["to"]
        if args.get("texts") is False: q["texts"] = 0
        return text_result(api("GET", "/notebooks/%s?%s" % (nb(args), urllib.parse.urlencode(q))))
    if name == "notes_image":
        q = pick(args, ["page", "x", "y", "w", "h", "width"])
        q.setdefault("width", 1000)
        data = api("GET", "/notebooks/%s/image?%s" % (nb(args), urllib.parse.urlencode(q)), raw=True)
        return {"content": [{"type": "image", "data": base64.b64encode(data).decode("ascii"), "mimeType": "image/jpeg"}]}
    if name == "notes_add_texts":
        body = pick(args, ["page", "boxes", "links", "x", "y", "gap"])
        return text_result(api("POST", "/notebooks/%s/texts" % nb(args), body))
    if name == "notes_add_pages":
        body = pick(args, ["after", "count", "paper", "pages"])
        if isinstance(body.get("after"), str) and body["after"].isdigit():
            body["after"] = int(body["after"])
        return text_result(api("POST", "/notebooks/%s/pages" % nb(args), body))
    if name == "notes_edit_text":
        body = pick(args, ["text", "x", "y", "width", "size", "bold", "color", "frame"])
        box = urllib.parse.quote(str(args.get("box", "")), safe="")
        return text_result(api("PATCH", "/notebooks/%s/texts/%s" % (nb(args), box), body))
    if name == "notes_delete_text":
        box = urllib.parse.quote(str(args.get("box", "")), safe="")
        return text_result(api("DELETE", "/notebooks/%s/texts/%s" % (nb(args), box)))
    if name == "notes_add_outline":
        body = pick(args, ["title", "page", "parent"])
        return text_result(api("POST", "/notebooks/%s/outline" % nb(args), body))
    if name == "notes_batch":
        body = pick(args, ["page", "delete", "deleteImages", "update", "move", "unlink", "add", "links", "x", "y", "gap"])
        return text_result(api("POST", "/notebooks/%s/batch" % nb(args), body))
    if name == "notes_measure":
        q = pick(args, ["page"])
        return text_result(api("GET", "/notebooks/%s/measure?%s" % (nb(args), urllib.parse.urlencode(q))))
    if name == "notes_add_image":
        path = os.path.expanduser(str(args.get("path", "")))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            raise ToolError("讀不到圖片檔：%s" % e)
        if len(data) > 20_000_000:
            raise ToolError("圖片太大（超過 20 MB）")
        body = pick(args, ["page", "x", "y", "width", "height", "above"])
        body["data"] = base64.b64encode(data).decode("ascii")
        return text_result(api("POST", "/notebooks/%s/images" % nb(args), body))
    if name == "notes_search":
        q = pick(args, ["q", "limit"])
        return text_result(api("GET", "/search?%s" % urllib.parse.urlencode(q)))
    if name == "notes_open":
        return text_result(api("POST", "/open", pick(args, ["notebook", "page", "rect"])))
    if name == "notes_ocr":
        q = pick(args, ["page", "x", "y", "w", "h"])
        return text_result(api("GET", "/notebooks/%s/ocr?%s" % (nb(args), urllib.parse.urlencode(q))))
    if name == "notes_new_notebook":
        return text_result(api("POST", "/notebooks", pick(args, ["title", "board", "folder"])))
    raise ToolError("沒有這個工具：%s" % name)


def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    mid = msg.get("id")
    if mid is None:
        return                                    # 通知（例如 notifications/initialized）不用回
    if method == "initialize":
        version = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": INSTRUCTIONS}})
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = msg.get("params") or {}
        try:
            result = run_tool(params.get("name"), params.get("arguments") or {})
        except ToolError as e:
            result = {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except Exception as e:                    # 不讓連接器整個掛掉
            result = {"content": [{"type": "text", "text": "連接器出錯：%r" % e}], "isError": True}
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "不支援：%s" % method}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "看不懂的訊息"}})
            continue
        if isinstance(msg, list):
            for m in msg:
                handle(m)
        else:
            handle(msg)


if __name__ == "__main__":
    main()
