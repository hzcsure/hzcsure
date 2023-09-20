#!/usr/bin/env python3

import os
from telethon import TelegramClient, events, sync
from telethon import functions, types
from telethon.sessions import StringSession

api_id = os.environ.get("API_ID", "")
api_hash = os.environ.get("API_HASH", "")
session_string = os.environ.get("SESSION_STRING", "")
send_to = os.environ.get("SEND_TO", "")
send_ms = os.environ.get("SEND_MS", "")
client = TelegramClient(StringSession(session_string), api_id, api_hash)
client.start()
client.send_message(send_to,send_ms)
for message in client.get_messages(send_to, limit=3):
    print(message.message)
#print(client.get_me().stringify())
