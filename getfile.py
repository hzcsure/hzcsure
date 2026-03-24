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
async def download_last_yaml():
    client = TelegramClient(StringSession(session_string), api_id, api_hash)
    await client.start()
    channel = await client.get_entity(CHANNEL)
    print(f"✅ 已连接频道：{channel.title}")

    # 存储所有未读的 yaml 文件
    unread_yaml_files = []

    # 遍历最新消息，只取未读
    async for msg in client.iter_messages(channel, limit=50):
        if msg.read:
            break  # 遇到已读就停止

        # 判断：是否是文件 + 文件名以 .yaml / .yml 结尾
        if msg.media and isinstance(msg.media, MessageMediaDocument):
            if msg.file and msg.file.name:
                if msg.file.name.endswith(('.yaml', '.yml')):
                    unread_yaml_files.append(msg)

    if not unread_yaml_files:
        print("\n❌ 未找到任何未读的 yaml 文件")
        await client.disconnect()
        return

    # ✅ 取【最后一个】yaml 文件
    last_yaml_msg = unread_yaml_files[-1]
    print(f"\n🎉 找到最后一个 yaml 文件：{last_yaml_msg.file.name}")

    # ✅ 下载并重命名为 Y.yaml
    save_path = await last_yaml_msg.download_media(file="Y.yaml")
    print(f"✅ 下载完成！保存路径：{save_path}")

    await client.disconnect()
    return save_path

# 运行
if __name__ == "__main__":
    import asyncio
    asyncio.run(download_last_yaml())
