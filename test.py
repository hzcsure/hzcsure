#!/usr/bin/env python3

import os
from telethon import TelegramClient, events, sync
from telethon import functions, types
from telethon.sessions import StringSession

print("hello telethon！！！")
print('ARG_A is {os.environ.get("ARG_A", "")}')
