#!/usr/bin/env python3

import os
from telethon import TelegramClient, events, sync
from telethon import functions, types
from telethon.sessions import StringSession

api_id = os.environ.get("API_ID", "")
api_hash = os.environ.get("API_HASH", "")
session_string = os.environ.get("SESSION_STRING", "")

client = TelegramClient(StringSession(session_string), api_id, api_hash)
client.start()
client.send_message('freenodeshare_bot', '/get')
for message in client.get_messages('freenodeshare_bot', limit=3):
    print(message.message)
#print(client.get_me().stringify())
