#!/usr/bin/env python3

import os
import re
from telethon import TelegramClient, events, sync
from telethon import functions, types
from telethon.sessions import StringSession
import asyncio
import time

api_id = os.environ.get("API_ID", "")
api_hash = os.environ.get("API_HASH", "")
session_string = os.environ.get("SESSION_STRING", "")
#client = TelegramClient(StringSession(session_string), api_id, api_hash)
CHANNEL = "https://t.me/SCHPD_SUB"
async def get_channel_history():
    # 1. 连接客户端
    client = TelegramClient(StringSession(session_string), api_id, api_hash)
    await client.start()

    # 2. 获取频道实体（必须先获取）
    channel = await client.get_entity(CHANNEL)
    print(f"✅ 成功获取频道：{channel.title}")

    # 3. 获取历史消息（核心代码）
    # limit=None = 获取全部消息；limit=100 = 只获取最新100条
    messages = await client.get_messages(channel, limit=None)

    # 4. 遍历打印消息
    print(f"\n📝 共获取到 {len(messages)} 条消息：\n")
    for msg in messages:
        print(f"[{msg.date}] 消息ID：{msg.id}")
        if msg.text:  # 如果有文本内容
            print(f"内容：{msg.text[:100]}...")  # 只打印前100字符避免过长
        print("-" * 50)

    await client.disconnect()

# 运行
if __name__ == "__main__":
    import asyncio
    asyncio.run(get_channel_history())
