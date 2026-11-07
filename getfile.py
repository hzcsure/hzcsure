#!/usr/bin/env python3

import os
import re
import base64
import asyncio

from telethon import TelegramClient, utils
from telethon.tl.types import (
    MessageMediaDocument, InputMessagesFilterDocument, InputMessagesFilterVideo,
    InputMessagesFilterRoundVideo, InputMessagesFilterGif, InputMessagesFilterMusic,
    InputMessagesFilterPhotos, InputMessagesFilterPhotoVideo,
)

api_id = os.environ.get("API_ID", "")
api_hash = os.environ.get("API_HASH", "")
SESSION = os.path.join(BASE_DIR, "tg_cli") = os.environ.get("SESSION_STRING", "")
#client = TelegramClient(StringSession(SESSION), api_id, api_hash)
# 服务器端消息过滤器（rule["filter"] 字段可选值，默认 "document"）
# 说明：InputMessagesFilterVideo 含视频与 GIF；圆形视频留言归 RoundVideo
# （新版 TL 没有 VideoNote，勿再找）；贴纸/自定义表情不属于任何这些过滤器的文件类。
FILTER_MAP = {
    "document": InputMessagesFilterDocument,     # 一切"文件"附件（默认）
    "video": InputMessagesFilterVideo,           # 视频消息（含 GIF）
    "round": InputMessagesFilterRoundVideo,      # 圆形视频留言
    "gif": InputMessagesFilterGif,               # GIF
    "music": InputMessagesFilterMusic,           # 音频
    "photo": InputMessagesFilterPhotos,          # 图片
    "photo_video": InputMessagesFilterPhotoVideo,# 图片+视频
}

# mime -> 扩展名（视频消息等无文件名时推断用）
MIME_EXT = {
    "video/mp4": ".mp4", "video/webm": ".webm", "video/quicktime": ".mov",
    "video/x-matroska": ".mkv", "video/avi": ".avi", "video/x-msvideo": ".avi",
    "video/mpeg": ".mpeg", "video/3gpp": ".3gp", "video/x-flv": ".flv",
    "image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp",
    "audio/mpeg": ".mp3", "audio/ogg": ".ogg", "audio/mp4": ".m4a",
    "application/pdf": ".pdf",
}


def msg_ext(msg):
    """取消息附件的扩展名（小写、带点）。文件名优先，其次 mime 推断；都没有返回 None。"""
    f = msg.file
    if f is None:
        return None
    if f.name and "." in f.name:
        return "." + f.name.rsplit(".", 1)[-1].lower()
    return MIME_EXT.get((getattr(f, "mime_type", "") or "").lower())


def _human_size(n):
    """字节数 -> 可读大小。"""
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024


def msg_display_name(msg):
    """用于打印的原始名：文件名 / mime 推断名 / 纯 ID。"""
    if msg.file and msg.file.name:
        return msg.file.name
    ext = msg_ext(msg) or ""
    return f"{ext.lstrip('.') or 'media'}_{msg.id}{ext}"

# ========================= 配置区：按需增删规则 =========================
DOWNLOAD_RULES = [
    {
        "channel": "1002327238192",
        #"filter": "video",             # 视频消息必须用 video 过滤器，document 会漏
        "types": [".yaml"],
        "count": 1,
        "save_names": ["Z.mp4"],  # 最新->Z，次新->Y，第三->X
    },
    # {
    #     "channel": "@some_channel",        # 或 t.me 链接或数字 ID
    #     "types": [".pdf", ".docx"],
    #     "count": 5,
    #     "save_dir": "downloads/docs",      # 不配则存脚本同目录
    # },
]
# ======================================================================




def resolve_channel_ref(raw):
    """把配置里的 channel 字符串归一化为 get_entity 可用的引用。

    支持 base64 用户名 / @username / t.me 链接 / 数字 ID；识别不了就原样传。
    """
    raw = str(raw).strip()
    if raw.startswith(("http://", "https://")) or raw.startswith("t.me/"):
        return "https://t.me/" + raw.split("t.me/")[-1].strip("/")
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    if raw.startswith("@"):
        return raw
    try:  # base64 用户名（如 c2NocGRfY2hhdAo= -> schpd_chat）
        decoded = base64.b64decode(raw, validate=True).decode("utf-8").strip()
        if re.fullmatch(r"[A-Za-z0-9_]{4,64}", decoded):
            return "https://t.me/" + decoded
    except Exception:
        pass
    return raw


async def process_rule(client, rule, index):
    """处理单条下载规则，返回下载文件数。单条失败不影响其他规则。"""
    label = f"规则[{index}] {rule.get('channel', '?')}"
    try:
        channel = await client.get_entity(resolve_channel_ref(rule["channel"]))
        title = getattr(channel, "title", None) or str(rule["channel"])
    except Exception as e:
        print(f"\n❌ {label}: 无法解析群组（{type(e).__name__}: {e}），跳过")
        return 0

    types = tuple(str(t).lower() for t in rule.get("types") or [])
    count = int(rule.get("count", 1))
    scan = int(rule.get("scan", 300))
    save_names = rule.get("save_names") or []
    save_dir = rule.get("save_dir") or BASE_DIR
    os.makedirs(save_dir, exist_ok=True)
    tl_filter = FILTER_MAP.get(str(rule.get("filter", "document")).lower(),
                               InputMessagesFilterDocument)

    print(f"\n===== 规则[{index}] {title} | 过滤器 {rule.get('filter', 'document')} "
          f"| 类型 {types} | 最新 {count} 个 =====")

    matched = []
    async for msg in client.iter_messages(channel, limit=scan, filter=tl_filter):
        if not types:
            hit = True                   # 未配 types：该类媒体全收
        else:
            ext = msg_ext(msg)
            hit = bool(ext) and ext in types
        if not hit:
            continue
        matched.append(msg)
        # 命中即打印：消息 ID / 日期 / 原始名 / mime / 大小，便于追溯
        sender = utils.get_display_name(await msg.get_sender()) or "?"
        f = msg.file
        print(f"  命中[{len(matched)}] msg_id={msg.id} | {msg.date:%Y-%m-%d %H:%M} | "
              f"{sender} | {f.name or '(无文件名)'} | {getattr(f, 'mime_type', '?') or '?'} | "
              f"{_human_size(getattr(f, 'size', None))}", flush=True)
        if len(matched) >= count:
            break   # 够数即停，省扫描时间

    if not matched:
        hint = "且扩展名为 " + str(types) if types else ""
        print(f"❌ 最近 {scan} 条消息内没有匹配的文件{hint}")
        return 0

    done = 0
    for i, msg in enumerate(matched):
        if save_names and i < len(save_names):
            fname = save_names[i]
        else:
            fname = msg_display_name(msg)
        path = await msg.download_media(file=os.path.join(save_dir, fname))
        if path:
            done += 1
            print(f"  [{done}/{len(matched)}] {msg_display_name(msg)} "
                  f"({msg.date:%Y-%m-%d %H:%M}) -> {fname}")
    return done


async def main():
    if not api_id or not api_hash:
        raise SystemExit("缺少凭据：请设置 TG_API_ID / TG_API_HASH（或 API_ID / API_HASH）")
    client = TelegramClient(SESSION, api_id, api_hash)
    await client.connect()
    if not await client.is_user_authorized():
        raise SystemExit("session 未授权：请先运行 python main.py me 完成登录")

    try:
        total = 0
        for i, rule in enumerate(DOWNLOAD_RULES, 1):
            total += await process_rule(client, rule, i)
        print(f"\n✅ 全部完成，共下载 {total} 个文件")
    finally:
        await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
