#!/usr/bin/env python3

import os
import re
from telethon import TelegramClient, events, sync
from telethon import functions, types
from telethon.sessions import StringSession
import time

api_id = os.environ.get("API_ID", "")
api_hash = os.environ.get("API_HASH", "")
session_string = os.environ.get("SESSION_STRING", "")
async def get_channel_id(channel_username):
    async with TelegramClient(session_string, api_id, api_hash) as client:
        # 支持 @xxx、t.me/xxx、频道名
        entity = await client.get_entity(channel_username)
        # 频道ID = -100 + 纯数字ID
        channel_id = entity.id
        full_id = f"-100{channel_id}"
        print(f"频道ID: {full_id}")
        return full_id

# 替换成你的频道
import asyncio
asyncio.run(get_channel_id("@SCHPD_SUB"))
