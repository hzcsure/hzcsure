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
client = TelegramClient(StringSession(session_string), api_id, api_hash)
client.start()
