#!/usr/bin/env python3

import calendar
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
import time
from zoneinfo import ZoneInfo

import tkinter as tk
from tkinter import ttk, messagebox, filedialog

SEG_DUR = 3.84
SCRIPT_DIR = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
if getattr(sys, "frozen", False):
    USER_DATA_DIR = os.path.join(
        os.path.expanduser("~/Library/Application Support"), "BBCD4"
    )
    os.makedirs(USER_DATA_DIR, exist_ok=True)
else:
    USER_DATA_DIR = SCRIPT_DIR
PRESETS_FILE = os.path.join(USER_DATA_DIR, "streams.json")
SETTINGS_FILE = os.path.join(USER_DATA_DIR, "settings.json")
DEFAULT_DOWNLOAD_DIR = os.path.expanduser("~/Downloads")
MAX_WORKERS = 20
DEFAULT_DOWNLOAD_ATTEMPTS = 4
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"
APP_VERSION = "1.1"
RELEASE_API_URL = "https://api.github.com/repos/baxterbloopington/BBCD4/releases/latest"

DEFAULT_STREAMS = {'ww 051 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_051/hevc_iptv_hd_abr_v1.mpd',
 'ww 051 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_051/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 052 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_052/hevc_iptv_hd_abr_v1.mpd',
 'ww 052 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_052/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 053 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_053/hevc_iptv_hd_abr_v1.mpd',
 'ww 053 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_053/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 054 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_054/hevc_iptv_hd_abr_v1.mpd',
 'ww 054 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_054/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 055 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_055/hevc_iptv_hd_abr_v1.mpd',
 'ww 055 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_055/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 056 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_056/hevc_iptv_hd_abr_v1.mpd',
 'ww 056 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_056/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 057 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_057/hevc_iptv_hd_abr_v1.mpd',
 'ww 057 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_057/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 058 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_058/hevc_iptv_hd_abr_v1.mpd',
 'ww 058 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_058/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 059 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_059/hevc_iptv_hd_abr_v1.mpd',
 'ww 059 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_059/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 051 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_051/hevc_iptv_hd_abr_v1.mpd',
 'uk 051 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_051/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 052 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_052/hevc_iptv_hd_abr_v1.mpd',
 'uk 052 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_052/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 053 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_053/hevc_iptv_hd_abr_v1.mpd',
 'uk 053 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_053/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 054 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_054/hevc_iptv_hd_abr_v1.mpd',
 'uk 054 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_054/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 055 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_055/hevc_iptv_hd_abr_v1.mpd',
 'uk 055 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_055/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 056 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_056/hevc_iptv_hd_abr_v1.mpd',
 'uk 056 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_056/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 057 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_057/hevc_iptv_hd_abr_v1.mpd',
 'uk 057 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_057/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 058 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_058/hevc_iptv_hd_abr_v1.mpd',
 'uk 058 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_058/t=3840/v=pv14/b=5070016/main.m3u8',
 'BBC Afghan (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_afghan_tv/t=3840/v=pv14/b=5070016/main.m3u8',
 'BBC Arabic (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_arabic_tv/t=3840/v=pv14/b=5070016/main.m3u8',
 'BBC Persian (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_persian_tv/t=3840/v=pv14/b=5070016/main.m3u8',
 'World Service 05 (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:world_service_stream_05/t=3840/v=pv14/b=5070016/main.m3u8',
 'World Service 06 (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:world_service_stream_06/t=3840/v=pv14/b=5070016/main.m3u8',
 'World Service 07 (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:world_service_stream_07/t=3840/v=pv14/b=5070016/main.m3u8',
 'World Service 08 (720p)': 'https://vs-hls-pushb-ww-live.akamaized.net/x=4/i=urn:bbc:pips:service:world_service_stream_08/t=3840/v=pv14/b=5070016/main.m3u8',
 'Video Pop Up Channel 01 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_01/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 02 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_02/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 03 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_03/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 04 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_04/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 05 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_05/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 06 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_06/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 07 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_07/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 08 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_08/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'Video Pop Up Channel 09 (720p)': 'https://vs-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:video_pop_up_channel_09/t=3840/v=pv14/b=5070016/main.fmp4.m3u8',
 'UHD 01': 'https://ve-uhd-push-uk.live.cf.md.bbci.co.uk/x=3/i=urn:bbc:pips:service:uhd_stream_01/iptv_uhd_v1.mpd',
 'UHD 02': 'https://ve-uhd-push-uk.live.cf.md.bbci.co.uk/x=3/i=urn:bbc:pips:service:uhd_stream_02/iptv_uhd_v1.mpd',
 'UHD 05': 'https://ve-uhd-push-uk.live.cf.md.bbci.co.uk/x=3/i=urn:bbc:pips:service:uhd_stream_05/iptv_uhd_v1.mpd',
 'ww 001 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_001/hevc_iptv_hd_abr_v1.mpd',
 'ww 001 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_001/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 002 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_002/hevc_iptv_hd_abr_v1.mpd',
 'ww 002 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_002/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 060 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_060/hevc_iptv_hd_abr_v1.mpd',
 'ww 060 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_060/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 061 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_061/hevc_iptv_hd_abr_v1.mpd',
 'ww 061 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_061/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 062 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_062/hevc_iptv_hd_abr_v1.mpd',
 'ww 062 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_062/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 063 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_063/hevc_iptv_hd_abr_v1.mpd',
 'ww 063 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_063/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 064 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_064/hevc_iptv_hd_abr_v1.mpd',
 'ww 064 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_064/t=3840/v=pv14/b=5070016/main.m3u8',
 'ww 065 (1080p)': 'https://ve-cmaf-pushb-ww.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_065/hevc_iptv_hd_abr_v1.mpd',
 'ww 065 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:ww_bbc_stream_065/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 001 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_001/hevc_iptv_hd_abr_v1.mpd',
 'uk 001 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_001/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 002 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_002/hevc_iptv_hd_abr_v1.mpd',
 'uk 002 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_002/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 003 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_003/hevc_iptv_hd_abr_v1.mpd',
 'uk 003 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_003/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 004 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_004/hevc_iptv_hd_abr_v1.mpd',
 'uk 004 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_004/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 005 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_005/hevc_iptv_hd_abr_v1.mpd',
 'uk 005 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_005/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 006 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_006/hevc_iptv_hd_abr_v1.mpd',
 'uk 006 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_006/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 007 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_007/hevc_iptv_hd_abr_v1.mpd',
 'uk 007 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_007/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 008 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_008/hevc_iptv_hd_abr_v1.mpd',
 'uk 008 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_008/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 009 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_009/hevc_iptv_hd_abr_v1.mpd',
 'uk 009 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_009/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 010 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_010/hevc_iptv_hd_abr_v1.mpd',
 'uk 010 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_010/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 011 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_011/hevc_iptv_hd_abr_v1.mpd',
 'uk 011 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_011/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 012 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_012/hevc_iptv_hd_abr_v1.mpd',
 'uk 012 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_012/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 013 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_013/hevc_iptv_hd_abr_v1.mpd',
 'uk 013 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_013/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 014 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_014/hevc_iptv_hd_abr_v1.mpd',
 'uk 014 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_014/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 015 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_015/hevc_iptv_hd_abr_v1.mpd',
 'uk 015 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_015/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 016 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_016/hevc_iptv_hd_abr_v1.mpd',
 'uk 016 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_016/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 017 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_017/hevc_iptv_hd_abr_v1.mpd',
 'uk 017 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_017/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 018 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_018/hevc_iptv_hd_abr_v1.mpd',
 'uk 018 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_018/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 019 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_019/hevc_iptv_hd_abr_v1.mpd',
 'uk 019 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_019/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 020 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_020/hevc_iptv_hd_abr_v1.mpd',
 'uk 020 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_020/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 021 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_021/hevc_iptv_hd_abr_v1.mpd',
 'uk 021 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_021/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 022 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_022/hevc_iptv_hd_abr_v1.mpd',
 'uk 022 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_022/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 023 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_023/hevc_iptv_hd_abr_v1.mpd',
 'uk 023 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_023/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 041 (4K/UHD)': 'https://ve-uhd-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:uk_bbc_stream_041/iptv_uhd_v1.mpd',
 'uk 042 (4K/UHD)': 'https://ve-uhd-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:uk_bbc_stream_042/iptv_uhd_v1.mpd',
 'uk 043 (4K/UHD)': 'https://ve-uhd-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:uk_bbc_stream_043/iptv_uhd_v1.mpd',
 'uk 044 (4K/UHD)': 'https://ve-uhd-push-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:uk_bbc_stream_044/iptv_uhd_v1.mpd',
 'uk 064 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_064/hevc_iptv_hd_abr_v1.mpd',
 'uk 064 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_064/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 069 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_069/hevc_iptv_hd_abr_v1.mpd',
 'uk 069 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_069/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 070 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_070/hevc_iptv_hd_abr_v1.mpd',
 'uk 070 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_070/t=3840/v=pv14/b=5070016/main.m3u8',
 'uk 071 (1080p)': 'https://ve-cmaf-pushb-uk.live.fastly.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_071/hevc_iptv_hd_abr_v1.mpd',
 'uk 071 (720p)': 'https://pub-m1-enhmi-sky.live.bidi.net.uk/ve-hls-pushb-uk/x=4/i=urn:bbc:pips:service:uk_bbc_stream_071/t=3840/v=pv14/b=5070016/main.m3u8',
 'BBC ONE LONDON HD': 'https://vs-cmaf-push-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_london/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE WALES HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_wales_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE SCOTLAND HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_scotland_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE NORTHERN IRELAND HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_northern_ireland_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE CHANNEL ISLANDS HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_channel_islands/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE EAST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_east/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE EAST MIDLANDS HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_east_midlands/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE EAST YORKSHIRE & LINCOLNSHIRE HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_east_yorkshire/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE NORTH EAST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_north_east/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE NORTH WEST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_north_west/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE SOUTH HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_south/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE SOUTH EAST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_south_east/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE SOUTH WEST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_south_west/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE WEST HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_west/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE WEST MIDLANDS HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_west_midlands/hevc_iptv_hd_abr_v1.mpd',
 'BBC ONE YORKSHIRE HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_one_yorks/hevc_iptv_hd_abr_v1.mpd',
 'BBC TWO HD': 'https://vs-cmaf-push-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_two_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC TWO NORTHERN IRELAND HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_two_northern_ireland_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC TWO WALES DIGITAL': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_two_wales_digital/hevc_iptv_hd_abr_v1.mpd',
 'BBC THREE HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_three_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC FOUR HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_four_hd/hevc_iptv_hd_abr_v1.mpd',
 'CBBC HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:cbbc_hd/hevc_iptv_hd_abr_v1.mpd',
 'CBEEBIES HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:cbeebies_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC SCOTLAND HD': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_scotland_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC NEWS CHANNEL HD': 'https://vs-cmaf-push-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_news_channel_hd/hevc_iptv_hd_abr_v1.mpd',
 'BBC PARLIAMENT': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_parliament/hevc_iptv_hd_abr_v1.mpd',
 'BBC ALBA': 'https://vs-cmaf-pushb-uk.live.cf.md.bbci.co.uk/x=4/i=urn:bbc:pips:service:bbc_alba/hevc_iptv_hd_abr_v1.mpd',
 'S4C (720p only)': 'https://vs-cmaf-pushb-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:s4cpbs/pc_hd_abr_v2.mpd'}
def load_streams():
    deleted = set()
    order = []
    if os.path.exists(PRESETS_FILE):
        with open(PRESETS_FILE, "r") as f:
            saved = json.load(f)
        if "streams" in saved:
            deleted = set(saved.get("deleted", []))
            order = saved.get("order", [])
            saved = saved["streams"]
        merged = DEFAULT_STREAMS.copy()
        merged.update(saved)
        for name in deleted:
            merged.pop(name, None)
        order = [name for name in order if name in merged]
        order.extend(name for name in sorted(merged, key=str.casefold) if name not in order)
        return merged, deleted, order
    return DEFAULT_STREAMS.copy(), deleted, sorted(DEFAULT_STREAMS, key=str.casefold)


def save_streams(streams, deleted, order):
    with open(PRESETS_FILE, "w") as f:
        json.dump({"streams": streams, "deleted": sorted(deleted), "order": order}, f, indent=2)


def load_settings():
    if os.path.exists(SETTINGS_FILE):
        with open(SETTINGS_FILE, "r") as f:
            return json.load(f)
    return {}


def save_settings(settings):
    with open(SETTINGS_FILE, "w") as f:
        json.dump(settings, f, indent=2)


def get_download_dir(settings):
    """Return the saved download folder, falling back to Downloads."""
    saved_folder = settings.get("download_dir", DEFAULT_DOWNLOAD_DIR)
    return os.path.expanduser(saved_folder)


def bounded_integer(value, default, minimum, maximum):
    try:
        return max(minimum, min(maximum, int(value)))
    except (TypeError, ValueError):
        return default


def default_duration_values():
    return (
        bounded_integer(settings.get("default_duration_hours"), 0, 0, 350),
        bounded_integer(settings.get("default_duration_minutes"), 1, 0, 59),
        bounded_integer(settings.get("default_duration_seconds"), 0, 0, 59),
    )


def download_retry_settings():
    attempts = bounded_integer(
        settings.get("download_attempts"), DEFAULT_DOWNLOAD_ATTEMPTS, 1, 10
    )
    try:
        delay = float(settings.get("retry_delay_seconds", 1))
    except (TypeError, ValueError):
        delay = 1
    return attempts, max(0, min(30, delay))


def get_ffmpeg_path():
    """Find the bundled ffmpeg first, then use a system installation."""
    candidates = (
        os.path.join(SCRIPT_DIR, "ffmpeg"),
        os.path.join(SCRIPT_DIR, "BBCD", "ffmpeg"),
        shutil.which("ffmpeg"),
    )
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise RuntimeError(
        "ffmpeg was not found. Put it beside this script or install it with Homebrew."
    )


def open_url(url, timeout=30):
    """Open URL with a normal browser-like user agent.

    Some CDN edges reject Python's default urllib user agent.
    """
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
        },
    )
    return urllib.request.urlopen(request, timeout=timeout)


def abs_url(base, path):
    return urllib.request.urljoin(base, path)


def segment_url(template, number):
    """Fill common DASH segment template number tokens."""
    url = template
    url = url.replace("$Number$", str(number))
    url = url.replace("$Time$", str(number))

    def repl(match):
        width = match.group(1)
        if width:
            return str(number).zfill(int(width))
        return str(number)

    url = re.sub(r"\$Number(?:%0(\d+)d)?\$", repl, url)
    return url


def parse_fmp4_hls_playlist(playlist_url):
    """Read an fMP4 HLS playlist and return its init file and media template."""
    playlist_data = open_url(playlist_url).read().decode("utf-8", "replace")
    base_url = playlist_url.rsplit("/", 1)[0] + "/"

    init_match = re.search(r'#EXT-X-MAP:.*?URI=["\']([^"\']+)["\']', playlist_data)
    if not init_match:
        raise RuntimeError("This fMP4 playlist does not provide an initialisation file.")

    media_lines = [
        line.strip() for line in playlist_data.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not media_lines:
        raise RuntimeError("This fMP4 playlist does not contain media segments.")

    media_path = media_lines[0]
    numbers = list(re.finditer(r"\d+", media_path))
    if not numbers:
        raise RuntimeError("Could not find a numbered media segment in this fMP4 playlist.")
    segment_number = max(numbers, key=lambda match: len(match.group(0)))
    media_template = (
        media_path[:segment_number.start()] + "$Number$" + media_path[segment_number.end():]
    )

    return {
        "init": abs_url(base_url, init_match.group(1)),
        "media": abs_url(base_url, media_template),
    }


def parse_mpd(mpd_url):
    data = open_url(mpd_url).read()
    root_xml = ET.fromstring(data)

    ns = {"mpd": root_xml.tag.split("}")[0].strip("{")} if "}" in root_xml.tag else {}
    base_url = mpd_url.rsplit("/", 1)[0] + "/"

    reps = []
    adaptation_sets = (
        root_xml.findall(".//mpd:AdaptationSet", ns)
        if ns
        else root_xml.findall(".//AdaptationSet")
    )

    for aset in adaptation_sets:
        content_type = aset.get("contentType", "")
        mime = aset.get("mimeType", "")
        aset_template = (
            aset.find("mpd:SegmentTemplate", ns)
            if ns
            else aset.find("SegmentTemplate")
        )

        reps_xml = (
            aset.findall("mpd:Representation", ns)
            if ns
            else aset.findall("Representation")
        )

        for rep in reps_xml:
            rep_template = (
                rep.find("mpd:SegmentTemplate", ns)
                if ns
                else rep.find("SegmentTemplate")
            )
            tmpl = rep_template if rep_template is not None else aset_template

            if tmpl is None:
                continue

            rep_id = rep.get("id", "")
            bandwidth = int(rep.get("bandwidth", "0"))
            codecs = rep.get("codecs", "")

            init = tmpl.get("initialization")
            media = tmpl.get("media")

            if not init or not media:
                continue

            init = init.replace("$RepresentationID$", rep_id)
            media = media.replace("$RepresentationID$", rep_id)

            is_audio = (
                "audio" in content_type
                or "audio" in mime
                or codecs.startswith("mp4a")
            )

            reps.append({
                "type": "audio" if is_audio else "video",
                "bandwidth": bandwidth,
                "init": abs_url(base_url, init),
                "media": abs_url(base_url, media),
            })

    videos = [r for r in reps if r["type"] == "video"]
    audios = [r for r in reps if r["type"] == "audio"]

    if not videos:
        raise RuntimeError("No video representation found in MPD.")
    if not audios:
        raise RuntimeError("No audio representation found in MPD.")

    if "iptv_uhd" in mpd_url or "ve-uhd" in mpd_url:
        video = min(videos, key=lambda r: abs(r["bandwidth"] - 18000000))
        audio = min(audios, key=lambda r: abs(r["bandwidth"] - 320000))
    else:
        video = max(videos, key=lambda r: r["bandwidth"])
        audio = max(audios, key=lambda r: r["bandwidth"])

    print("Selected video:", video, flush=True)
    print("Selected audio:", audio, flush=True)

    return video, audio


def download(url, output, attempts=None):
    """
    Download a URL to a file, retrying failures.

    attempts=4 means:
    - 1 normal attempt
    - 3 further retries

    The file is first written to .part and only moved into place
    after a successful download, so failed attempts do not leave
    broken segment files behind.
    """
    if attempts is None:
        attempts, retry_delay = download_retry_settings()
    else:
        attempts = bounded_integer(attempts, DEFAULT_DOWNLOAD_ATTEMPTS, 1, 10)
        retry_delay = download_retry_settings()[1]

    part_output = output + ".part"
    last_error = None

    for attempt in range(1, attempts + 1):
        try:
            if os.path.exists(part_output):
                os.remove(part_output)

            with open_url(url, timeout=30) as response:
                with open(part_output, "wb") as out:
                    shutil.copyfileobj(response, out)

            os.replace(part_output, output)
            return

        except Exception as e:
            last_error = e

            if os.path.exists(part_output):
                try:
                    os.remove(part_output)
                except OSError:
                    pass

            if attempt < attempts:
                time.sleep(retry_delay)

    raise RuntimeError(f"Failed after {attempts} attempts: {url}\n{last_error}")


def start_processing_progress(message):
    """Keep the completed download bar full while ffmpeg finishes."""
    status.set(message)
    progress.stop()
    progress.configure(mode="determinate", value=progress["maximum"])
    root.update_idletasks()


def stop_processing_progress():
    progress.stop()
    progress.configure(mode="determinate")

DATE_FORMATS = (
    "%d-%m-%Y", "%Y-%m-%d", "%m-%d-%Y",
    "%d/%m/%Y", "%Y/%m/%d", "%m/%d/%Y",
    "%d.%m.%Y", "%Y.%m.%d", "%m.%d.%Y",
    "%d %m %Y", "%Y %m %d", "%m %d %Y",
    "%d %b %Y", "%b %d %Y",
)
DATE_FORMAT_DESCRIPTIONS = {
    "%d-%m-%Y": "dd-mm-yyyy", "%Y-%m-%d": "yyyy-mm-dd", "%m-%d-%Y": "mm-dd-yyyy",
    "%d/%m/%Y": "dd/mm/yyyy", "%Y/%m/%d": "yyyy/mm/dd", "%m/%d/%Y": "mm/dd/yyyy",
    "%d.%m.%Y": "dd.mm.yyyy", "%Y.%m.%d": "yyyy.mm.dd", "%m.%d.%Y": "mm.dd.yyyy",
    "%d %m %Y": "dd mm yyyy", "%Y %m %d": "yyyy mm dd", "%m %d %Y": "mm dd yyyy",
}
LEGACY_DATE_FORMATS = {
    "DD-MM-YYYY": "%d-%m-%Y",
    "YYYY-MM-DD": "%Y-%m-%d",
    "MM-DD-YYYY": "%m-%d-%Y",
    "30 Mar 2026": "%d %b %Y",
    "Mar 30 2026": "%b %d %Y",
}


def active_date_format():
    selected_format = settings.get("date_format", "%d-%m-%Y")
    if selected_format in DATE_FORMATS:
        return selected_format
    return LEGACY_DATE_FORMATS.get(selected_format, "%d-%m-%Y")


def date_format_choices():
    """Show today's date alongside a clear description of each numeric layout."""
    today = datetime.now()
    choices = []
    for date_format in DATE_FORMATS:
        example = today.strftime(date_format)
        description = DATE_FORMAT_DESCRIPTIONS.get(date_format)
        label = f"{example} ({description})" if description else example
        choices.append((label, date_format))
    return choices


def format_display_date(value):
    return value.strftime(active_date_format())


def parse_display_date(value):
    return datetime.strptime(value.strip(), active_date_format())


def run_download():
    old_cwd = os.getcwd()
    tmp = None

    try:
        name = selected_stream.get()
        stream_url = streams[name]

        is_dash = stream_url.endswith(".mpd")
        is_hls = stream_url.endswith(".m3u8")
        is_fmp4_hls = is_hls and ".fmp4.m3u8" in stream_url.lower()

        if not (is_dash or is_hls):
            raise RuntimeError("Stream URL must be an .mpd or .m3u8")

        date_text = date_entry.get().strip()
        time_text = time_choice.get().strip()

        h = int(hours_spinbox.get() or 0)
        m = int(minutes_spinbox.get() or 0)
        s = int(seconds_spinbox.get() or 0)

        if h < 0 or not 0 <= m <= 59 or not 0 <= s <= 59:
            raise ValueError("I admire attempt, but we can't just make more time. Minutes and seconds must be 0–59.")

        duration = h * 3600 + m * 60 + s

        if duration <= 0:
            raise ValueError("Choose a video duration.")

        # Accept HH:MM as well as HH:MM:SS - minutes-only times end with :00
        if len(time_text) == 5:
            time_text += ":00"

        local_dt = datetime.combine(
            parse_display_date(date_text).date(),
            datetime.strptime(time_text, "%H:%M:%S").time(),
        )

        london = ZoneInfo("Europe/London")
        now = datetime.now(london)
        if (now.date() - local_dt.date()).days >= 15:
            status.set("Choose a date within the last 14 days.")
            messagebox.showwarning(
                "Date too old",
                "Woah there, you can only download streams from the past 14 days."
            )
            return
        if local_dt.replace(tzinfo=london) > now:
            status.set("Choose a time that has already happened.")
            messagebox.showwarning(
                "Future date and time",
                "Look, I like jabbing buttons too, but you can't download something that hasn't happened yet..."
            )
            return

        if settings.get("confirm_before_download", False):
            duration_label = f"{h}h {m}m {s}s"
            if not messagebox.askyesno(
                "Start download",
                f"Download {name}?\n\nStart: {date_text} {time_text}\nDuration: {duration_label}",
            ):
                status.set("Ready")
                return

        unix_time = local_dt.replace(
            tzinfo=london
        ).timestamp()

        start_segment = math.floor(unix_time / SEG_DUR)

        end_unix_time = unix_time + duration
        end_segment = math.ceil(end_unix_time / SEG_DUR) - 1

        count = end_segment - start_segment + 1

        match = re.search(r"(ww|uk)\s+(\d+)", name, re.I)

        if match:
            stream_id = f"{match.group(1).lower()}_{match.group(2)}"
        else:
            stream_id = name.replace(" ", "_").replace("/", "_")

        output = os.path.join(
            DOWNLOAD_DIR,
            f"{stream_id}_{start_segment}.mp4"
        )

        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        ffmpeg_path = get_ffmpeg_path()

        if is_dash:
            status.set("Reading MPD...")
            root.update_idletasks()

            video, audio = parse_mpd(stream_url)

        elif is_fmp4_hls:
            status.set("Reading fMP4 playlist...")
            root.update_idletasks()

            fmp4 = parse_fmp4_hls_playlist(stream_url)

        else:
            status.set("Reading HLS playlist...")
            root.update_idletasks()

            base_url = stream_url.rsplit("/", 1)[0] + "/"

        tmp = tempfile.mkdtemp(prefix="bbc_segments_")
        os.chdir(tmp)

        if is_dash:

            status.set("Downloading init files...")
            root.update_idletasks()

            print("Video init URL:", video["init"], flush=True)
            print("Audio init URL:", audio["init"], flush=True)
            print("First video segment URL:",
                  segment_url(video["media"], start_segment),
                  flush=True)
            print("First audio segment URL:",
                  segment_url(audio["media"], start_segment),
                  flush=True)

            download(video["init"], "video.init")
            download(audio["init"], "audio.init")

        elif is_fmp4_hls:

            status.set("Downloading fMP4 initialisation file...")
            root.update_idletasks()

            print("fMP4 init URL:", fmp4["init"], flush=True)
            print("First fMP4 segment URL:",
                  segment_url(fmp4["media"], start_segment),
                  flush=True)
            download(fmp4["init"], "fmp4.init")

        else:

            print("First TS segment:",
                  base_url + f"{start_segment}.ts",
                  flush=True)

        def download_segment_pair(seg):
            v_url = segment_url(video["media"], seg)
            a_url = segment_url(audio["media"], seg)

            download(v_url, f"v_{seg}.m4s")
            download(a_url, f"a_{seg}.m4s")

            return seg
            
        def download_fmp4(seg):
            fragment_url = segment_url(fmp4["media"], seg)
            download(fragment_url, f"f_{seg}.m4s")
            return seg

        def download_ts(seg):

            ts_url = base_url + f"{seg}.ts"
            
            download(ts_url, f"{seg}.ts")

            return seg

        requested_segments = list(range(start_segment, end_segment + 1))
        downloaded_segments = []
        failed_segments = {}
        done = 0
        progress.configure(maximum=len(requested_segments), value=0)

        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
            if is_dash:

                futures = {
                    executor.submit(download_segment_pair, seg): seg
                    for seg in requested_segments
                }

            elif is_fmp4_hls:

                futures = {
                    executor.submit(download_fmp4, seg): seg
                    for seg in requested_segments
                }

            else:

                futures = {
                    executor.submit(download_ts, seg): seg
                    for seg in requested_segments
                }

            for future in as_completed(futures):
                seg = futures[future]

                try:
                    future.result()
                    downloaded_segments.append(seg)
                except Exception as e:
                    failed_segments[seg] = str(e)
                    print(f"Segment {seg} failed: {e}", flush=True)

                done += 1
                failed_count = len(failed_segments)

                status.set(f"Downloading {done}/{len(requested_segments)} segments...")
                progress.configure(value=done)
                root.update_idletasks()

        downloaded_segments.sort()

        while failed_segments:
            failed_list = sorted(failed_segments)
            first_failed = failed_list[0]
            choice = show_failed_segments_dialog()

            if choice == "abort":
                raise RuntimeError("Download cancelled because segments failed.")

            if choice == "save":
                segments = [
                    seg for seg in requested_segments
                    if seg < first_failed and seg in downloaded_segments
                ]
                if not segments:
                    raise RuntimeError("No usable downloaded segments to combine.")
                break

            # Start again at the earliest missing segment
            retry_segments = [seg for seg in requested_segments if seg >= first_failed]
            segment_downloader = (
                download_segment_pair if is_dash
                else download_fmp4 if is_fmp4_hls
                else download_ts
            )
            failed_segments = {}

            for retry_done, seg in enumerate(retry_segments, start=1):
                status.set(
                    f"Trying again from the failed segment "
                    f"({retry_done}/{len(retry_segments)})..."
                )
                root.update_idletasks()
                try:
                    segment_downloader(seg)
                    if seg not in downloaded_segments:
                        downloaded_segments.append(seg)
                except Exception as error:
                    failed_segments[seg] = str(error)
                    print(f"Segment {seg} failed again: {error}", flush=True)

            downloaded_segments.sort()
        else:
            segments = downloaded_segments

        if is_dash:

            status.set("Combining video fragments...")
            root.update_idletasks()

            with open("video.mp4", "wb") as out:
                with open("video.init", "rb") as init_file:
                    out.write(init_file.read())

                for seg in segments:
                    with open(f"v_{seg}.m4s", "rb") as part:
                        out.write(part.read())

            status.set("Combining audio fragments...")
            root.update_idletasks()

            with open("audio.mp4", "wb") as out:
                with open("audio.init", "rb") as init_file:
                    out.write(init_file.read())

                for seg in segments:
                    with open(f"a_{seg}.m4s", "rb") as part:
                        out.write(part.read())

            start_processing_progress(
                "Encoding"
                if encode_h265.get() else "Merging segments"
            )

            ffmpeg_args = [
                ffmpeg_path,
                "-y",
                "-i", "video.mp4",
                "-i", "audio.mp4",
            ]
            ffmpeg_args.extend(["-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "copy"] if encode_h265.get() else ["-c", "copy"])
            subprocess.check_call(ffmpeg_args + [output])

        elif is_fmp4_hls:

            status.set("Combining fMP4 fragments...")
            root.update_idletasks()

            with open("fmp4.mp4", "wb") as out:
                with open("fmp4.init", "rb") as init_file:
                    out.write(init_file.read())
                for seg in segments:
                    with open(f"f_{seg}.m4s", "rb") as part:
                        out.write(part.read())

            start_processing_progress(
                "Encoding"
                if encode_h265.get() else "Merging fragments"
            )
            ffmpeg_args = [ffmpeg_path, "-y", "-i", "fmp4.mp4"]
            ffmpeg_args.extend(
                ["-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "copy"]
                if encode_h265.get() else ["-c", "copy"]
            )
            subprocess.check_call(ffmpeg_args + [output])

        else:

            start_processing_progress(
                "Encoding"
                if encode_h265.get() else "Joining TS files..."
            )

            with open("list.txt", "w") as f:
                for seg in segments:
                    f.write(f"file '{seg}.ts'\n")

            ffmpeg_args = [
                ffmpeg_path,
                "-y",
                "-f", "concat",
                "-safe", "0",
                "-i", "list.txt",
            ]
            ffmpeg_args.extend(["-c:v", "libx265", "-tag:v", "hvc1", "-c:a", "copy"] if encode_h265.get() else ["-c", "copy"])
            subprocess.check_call(ffmpeg_args + [output])

        os.chdir(old_cwd)
        shutil.rmtree(tmp, ignore_errors=True)

        stop_processing_progress()
        progress.configure(value=progress["maximum"])
        status.set("Done!")
        if settings.get("reveal_finished_video", False):
            reveal_finished_video(output)
        show_finished_dialog(output)

    except Exception as e:
        os.chdir(old_cwd)

        stop_processing_progress()

        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)

        status.set("Error")
        messagebox.showerror("Error", str(e))


def place_on_screen(window, preferred_x, preferred_y):
    """Place a popout fully within the current screen."""
    window.update_idletasks()
    max_x = max(0, window.winfo_screenwidth() - window.winfo_reqwidth())
    max_y = max(0, window.winfo_screenheight() - window.winfo_reqheight())
    x = max(0, min(preferred_x, max_x))
    y = max(0, min(preferred_y, max_y))
    window.geometry(f"+{x}+{y}")


def show_failed_segments_dialog():
    """Ask how to proceed when one or more stream segments cannot be fetched."""
    dialog = tk.Toplevel(root)
    dialog.withdraw()
    dialog.title("Some segments could not be downloaded")
    dialog.resizable(False, False)
    dialog.transient(root)
    choice = {"value": "abort"}

    frame = ttk.Frame(dialog, padding=16)
    frame.grid()
    ttk.Label(frame, text="Some segments could not be downloaded", font=SECTION_TITLE_FONT).grid(
        row=0, column=0, columnspan=3, sticky="w", pady=(0, 12)
    )
    ttk.Label(
        frame,
        text=("You can either:\n"
              "- Try downloading again from the failed segment\n"
              "- Save video of everything up to the failed segment\n"
              "- Abort without creating video"),
        justify="left",
    ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(0, 14))

    buttons = ttk.Frame(frame)
    buttons.grid(row=2, column=0, columnspan=3, sticky="e")

    def select(value):
        choice["value"] = value
        dialog.destroy()

    make_blue_button(buttons, "Try again", lambda: select("retry"), width=8).pack(side="left")
    make_neutral_button(buttons, "Save", lambda: select("save"), width=8).pack(side="left", padx=(8, 0))
    make_red_button(buttons, "Abort", lambda: select("abort"), width=8).pack(side="left", padx=(8, 0))
    dialog.bind("<Return>", lambda event: (select("retry"), "break")[1])
    dialog.bind("<Escape>", lambda event: (select("abort"), "break")[1])
    dialog.protocol("WM_DELETE_WINDOW", lambda: select("abort"))
    place_on_screen(
        dialog,
        root.winfo_rootx() + (root.winfo_width() // 2),
        root.winfo_rooty() + (root.winfo_height() // 2),
    )
    dialog.deiconify()
    dialog.grab_set()
    root.wait_window(dialog)
    return choice["value"]


def show_finished_dialog(output):
    """Offer to open a completed video without leaving the app."""
    dialog = tk.Toplevel(root)
    dialog.withdraw()
    dialog.title("Finished")
    dialog.resizable(False, False)
    dialog.transient(root)

    frame = ttk.Frame(dialog, padding=16)
    frame.grid()
    ttk.Label(frame, text=f"Saved to:\n{output}", justify="left", wraplength=430).grid(
        row=0, column=0, columnspan=2, sticky="w", pady=(0, 14)
    )
    buttons = ttk.Frame(frame)
    buttons.grid(row=1, column=0, columnspan=2, sticky="e")

    def show_video():
        try:
            subprocess.Popen(["open", output])
        except OSError as error:
            messagebox.showerror("Could not open video", str(error), parent=dialog)
            return
        dialog.destroy()

    make_blue_button(buttons, "Show video", show_video, width=12).pack(side="right")
    make_neutral_button(buttons, "OK", dialog.destroy, width=8).pack(side="right", padx=(0, 8))
    dialog.bind("<Return>", lambda event: (dialog.destroy(), "break")[1])
    dialog.protocol("WM_DELETE_WINDOW", dialog.destroy)
    place_on_screen(
        dialog,
        root.winfo_rootx() + (root.winfo_width() // 2),
        root.winfo_rooty() + (root.winfo_height() // 2),
    )
    dialog.deiconify()
    dialog.grab_set()


def enable_drag_selection_scroll(entry):
    """Let a selection continue moving through a long one-line entry."""
    def scroll_selection(event):
        if event.x <= 2:
            entry.xview_scroll(-1, "units")
        elif event.x >= entry.winfo_width() - 2:
            entry.xview_scroll(1, "units")
    entry.bind("<B1-Motion>", scroll_selection, add="+")


def choose_date():
    """Open a small calendar and put the selected date in the date field."""
    try:
        shown = parse_display_date(date_entry.get())
    except ValueError:
        shown = datetime.now()
    selected_date = shown.date()

    popup = tk.Toplevel(root)
    popup.withdraw()
    popup.title("Choose start date")
    popup.resizable(False, False)
    popup.transient(root)

    month = tk.IntVar(value=shown.month)
    year = tk.IntVar(value=shown.year)
    title = tk.StringVar()
    grid = tk.Frame(popup, padx=8, pady=8, bg=popup.cget("bg"))
    grid.grid()
    for column in range(7):
        grid.columnconfigure(column, weight=1, uniform="calendar-days")

    def change_month(offset):
        new_month = month.get() + offset
        new_year = year.get()
        if new_month == 0:
            new_month, new_year = 12, new_year - 1
        elif new_month == 13:
            new_month, new_year = 1, new_year + 1
        month.set(new_month)
        year.set(new_year)
        draw_calendar()

    def select_day(day):
        selected = datetime(year.get(), month.get(), day).date()
        today = datetime.now(ZoneInfo("Europe/London")).date()
        if (today - selected).days >= 15:
            messagebox.showwarning(
                "Date too old",
                "Woah there, you can only download streams from the past 14 days."
            )
            return
        if selected > today:
            messagebox.showwarning(
                "Future date",
                "Look, I like jabbing buttons too, but you can't download something that hasn't happened yet..."
            )
            return
        date_entry.delete(0, tk.END)
        date_entry.insert(0, format_display_date(selected))
        popup.destroy()

    def draw_calendar():
        for child in grid.winfo_children():
            child.destroy()

        title.set(datetime(year.get(), month.get(), 1).strftime("%B %Y"))

        def calendar_arrow(symbol, command, column, sticky):
            arrow = tk.Label(grid, text=symbol, width=3, padx=8, pady=5,
                             bg="#888888", fg="white", anchor="center")
            arrow.grid(row=0, column=column, sticky=sticky)
            arrow.bind("<Button-1>", lambda event: command())
            arrow.bind("<Enter>", lambda event: arrow.configure(bg="#A6A6A6"))
            arrow.bind("<Leave>", lambda event: arrow.configure(bg="#888888"))

        calendar_arrow("‹", lambda: change_month(-1), 0, "w")
        ttk.Label(grid, textvariable=title, anchor="center", width=18).grid(row=0, column=1, columnspan=5)
        calendar_arrow("›", lambda: change_month(1), 6, "e")

        for column, day_name in enumerate(("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")):
            tk.Label(grid, text=day_name, anchor="center", fg="#e6e6e6",
                     bg=popup.cget("bg")).grid(row=1, column=column, sticky="ew", pady=(6, 2))

        first_weekday, days_in_month = calendar.monthrange(year.get(), month.get())
        for day in range(1, days_in_month + 1):
            position = first_weekday + day - 1
            row, column = divmod(position, 7)
            date_for_button = datetime(year.get(), month.get(), day).date()
            selected = date_for_button == selected_date
            normal_colour = "#0A84FF" if selected else "#888888"
            hover_colour = "#5BA7FF" if selected else "#A6A6A6"
            day_tile = tk.Label(
                grid, text=str(day), anchor="center", padx=8, pady=5,
                bg=normal_colour, fg="white",
            )
            day_tile.grid(row=row + 2, column=column, sticky="ew", padx=4, pady=4)
            day_tile.bind("<Button-1>", lambda event, d=day: select_day(d))
            day_tile.bind("<Enter>", lambda event, tile=day_tile, colour=hover_colour: tile.configure(bg=colour))
            day_tile.bind("<Leave>", lambda event, tile=day_tile, colour=normal_colour: tile.configure(bg=colour))

    draw_calendar()
    place_on_screen(
        popup, date_entry.winfo_rootx(),
        date_entry.winfo_rooty() + date_entry.winfo_height(),
    )
    popup.deiconify()
    popup.grab_set()


def is_supported_stream_url(url):
    """Return True only for a complete web URL ending in a supported playlist type."""
    return bool(re.fullmatch(r"https?://[^\s]+\.(?:mpd|m3u8)", url, re.IGNORECASE))


def add_stream(name_entry, url_entry, on_saved=None):
    name = name_entry.get().strip()
    url = url_entry.get().strip()
    if getattr(name_entry, "placeholder", None) == name:
        name = ""
    if getattr(url_entry, "placeholder", None) == url:
        url = ""

    if not name or not url:
        messagebox.showerror("Error", "Enter both a stream name and URL.")
        return False
    if not is_supported_stream_url(url):
        messagebox.showwarning(
            "Invalid stream URL",
            "That doesn't look like a valid stream URL ending in .mpd or .m3u8.",
        )
        url_entry.focus_set()
        return False
    if name in streams:
        messagebox.showerror("Name already used", "A saved stream already has that name.")
        return False

    streams[name] = url
    deleted_streams.discard(name)
    if name not in stream_order:
        stream_order.append(name)
    save_streams(streams, deleted_streams, stream_order)

    selected_stream.set(name)
    refresh_stream_button()

    name_entry.delete(0, tk.END)
    url_entry.delete(0, tk.END)
    if hasattr(name_entry, "placeholder"):
        restore_placeholder(name_entry)
    if hasattr(url_entry, "placeholder"):
        restore_placeholder(url_entry)
    if on_saved:
        on_saved(name)
    return True


def refresh_stream_button():
    stream_selector.configure(values=stream_order)
    stream_selector.set(selected_stream.get() or "")


def update_save_location():
    save_location.set(f"Files save to {DOWNLOAD_DIR}")


def reveal_finished_video(output):
    """Reveal the finished MP4 in Finder without opening the video player."""
    try:
        subprocess.Popen(["open", "-R", output])
    except OSError as error:
        print(f"Could not reveal finished video: {error}", flush=True)


def open_discord_invite():
    """Open the Discord server invite in the system's default browser."""
    invite_url = "https://discord.gg/KRWsWmFS5r"
    try:
        subprocess.Popen(["open", invite_url])
    except OSError as error:
        messagebox.showerror("Could not open Discord", str(error))


def choose_download_folder(event=None):
    """Let the user pick, and remember, the folder used for finished videos."""
    global DOWNLOAD_DIR
    initial_dir = DOWNLOAD_DIR if os.path.isdir(DOWNLOAD_DIR) else DEFAULT_DOWNLOAD_DIR
    selected_folder = filedialog.askdirectory(
        title="Choose where videos are saved",
        initialdir=initial_dir,
        mustexist=True,
    )
    if not selected_folder:
        return
    DOWNLOAD_DIR = selected_folder
    settings["download_dir"] = DOWNLOAD_DIR
    save_settings(settings)
    update_save_location()


def remember_encode_choice():
    settings["encode_h265"] = encode_h265.get()
    save_settings(settings)


def show_settings():
    dialog = tk.Toplevel(root)
    dialog.withdraw()
    dialog.title("Settings")
    dialog.resizable(False, False)
    dialog.transient(root)

    frame = ttk.Frame(dialog, padding=16)
    frame.grid()
    frame.columnconfigure(0, weight=1)
    ttk.Label(frame, text="Settings", font=SECTION_TITLE_FONT).grid(
        row=0, column=0, sticky="w", pady=(0, 12)
    )

    # Date display
    ttk.Label(frame, text="Date display", font=STREAM_SECTION_FONT).grid(
        row=1, column=0, sticky="w"
    )
    ttk.Label(frame, text="Date format", font=FORM_LABEL_FONT).grid(
        row=2, column=0, sticky="w", pady=(4, 2)
    )
    choices = date_format_choices()
    labels = [label for label, _ in choices]
    label_to_format = dict(choices)
    format_choice = ttk.Combobox(frame, values=labels, state="readonly", width=29)
    current_format = active_date_format()
    format_choice.set(next(label for label, date_format in choices if date_format == current_format))
    format_choice.grid(row=3, column=0, sticky="w", pady=(0, 14))

    def change_date_format(event=None):
        try:
            current_date = parse_display_date(date_entry.get())
        except ValueError:
            current_date = datetime.now()
        settings["date_format"] = label_to_format[format_choice.get()]
        save_settings(settings)
        date_entry.delete(0, tk.END)
        date_entry.insert(0, format_display_date(current_date))

    format_choice.bind("<<ComboboxSelected>>", change_date_format)
    ttk.Separator(frame).grid(row=4, column=0, sticky="ew", pady=(0, 14))

    # Download defaults
    ttk.Label(frame, text="Download defaults", font=STREAM_SECTION_FONT).grid(
        row=5, column=0, sticky="w"
    )
    ttk.Label(frame, text="Default duration", font=FORM_LABEL_FONT).grid(
        row=6, column=0, sticky="w", pady=(4, 2)
    )
    default_hours, default_minutes, default_seconds = default_duration_values()
    duration_row = ttk.Frame(frame)
    duration_row.grid(row=7, column=0, sticky="w", pady=(0, 6))
    duration_values = [
        make_stepper(duration_row, "Hours", default_hours, 0, 350),
        make_stepper(duration_row, "Minutes", default_minutes, 0, 59),
        make_stepper(duration_row, "Seconds", default_seconds, 0, 59),
    ]

    default_h265 = tk.BooleanVar(value=encode_h265.get())

    def save_h265_default():
        settings["encode_h265"] = default_h265.get()
        encode_h265.set(default_h265.get())
        save_settings(settings)

    ttk.Checkbutton(
        frame, text="Encode to H.265 by default", variable=default_h265,
        command=save_h265_default,
    ).grid(row=8, column=0, sticky="w", pady=(0, 14))
    ttk.Separator(frame).grid(row=9, column=0, sticky="ew", pady=(0, 14))

    # Download folder
    ttk.Label(frame, text="Download folder", font=STREAM_SECTION_FONT).grid(
        row=10, column=0, sticky="w"
    )
    folder_row = ttk.Frame(frame)
    folder_row.grid(row=11, column=0, sticky="w", pady=(4, 14))
    ttk.Label(folder_row, textvariable=save_location).pack(side="left")
    make_blue_button(folder_row, "Choose folder…", choose_download_folder, width=16).pack(
        side="left", padx=(12, 0)
    )
    ttk.Separator(frame).grid(row=12, column=0, sticky="ew", pady=(0, 14))

    # Download behaviour
    ttk.Label(frame, text="Download behaviour", font=STREAM_SECTION_FONT).grid(
        row=13, column=0, sticky="w"
    )
    confirm_before_download = tk.BooleanVar(value=bool(settings.get("confirm_before_download", False)))
    reveal_finished = tk.BooleanVar(value=bool(settings.get("reveal_finished_video", False)))

    def save_download_behaviour():
        settings["confirm_before_download"] = confirm_before_download.get()
        settings["reveal_finished_video"] = reveal_finished.get()
        save_settings(settings)

    ttk.Checkbutton(
        frame, text="Confirm before starting a download", variable=confirm_before_download,
        command=save_download_behaviour,
    ).grid(row=14, column=0, sticky="w", pady=(4, 2))
    ttk.Checkbutton(
        frame, text="Reveal finished video in Finder", variable=reveal_finished,
        command=save_download_behaviour,
    ).grid(row=15, column=0, sticky="w", pady=(0, 14))
    ttk.Separator(frame).grid(row=16, column=0, sticky="ew", pady=(0, 14))

    # Retry behaviour
    ttk.Label(frame, text="Retry failed segments", font=STREAM_SECTION_FONT).grid(
        row=17, column=0, sticky="w"
    )
    attempts, retry_delay = download_retry_settings()
    retry_row = ttk.Frame(frame)
    retry_row.grid(row=18, column=0, sticky="w", pady=(4, 14))
    ttk.Label(retry_row, text="Attempts", font=FORM_LABEL_FONT).pack(side="left")
    attempts_input = make_stepper_control(retry_row, attempts, 1, 10)
    attempts_input.master.pack(side="left", padx=(6, 16))
    ttk.Label(retry_row, text="Seconds between attempts", font=FORM_LABEL_FONT).pack(side="left")
    delay_input = make_stepper_control(
        retry_row, retry_delay, 0, 30, width=5, step=0.5, allow_decimal=True
    )
    delay_input.master.pack(side="left", padx=(6, 0))
    ttk.Separator(frame).grid(row=19, column=0, sticky="ew", pady=(0, 14))

    # Stream management
    ttk.Label(frame, text="Stream management", font=STREAM_SECTION_FONT).grid(
        row=20, column=0, sticky="w"
    )
    skip_delete = tk.BooleanVar(value=bool(settings.get("skip_delete_confirmation", False)))

    def save_skip_delete():
        settings["skip_delete_confirmation"] = skip_delete.get()
        save_settings(settings)

    ttk.Checkbutton(
        frame, text="Skip confirmation when deleting streams", variable=skip_delete,
        command=save_skip_delete,
    ).grid(row=21, column=0, sticky="w", pady=(4, 14))
    ttk.Separator(frame).grid(row=22, column=0, sticky="ew", pady=(0, 14))

    ttk.Label(frame, text="Updates", font=STREAM_SECTION_FONT).grid(
        row=23, column=0, sticky="w"
    )
    check_updates = tk.BooleanVar(value=bool(settings.get("check_updates_on_launch", True)))

    def save_update_preference():
        settings["check_updates_on_launch"] = check_updates.get()
        save_settings(settings)

    ttk.Checkbutton(
        frame, text="Check for updates when BBCD4 opens", variable=check_updates,
        command=save_update_preference,
    ).grid(row=24, column=0, sticky="w", pady=(4, 14))

    def save_duration_and_retry_settings():
        hours = bounded_integer(duration_values[0].get(), 0, 0, 350)
        minutes = bounded_integer(duration_values[1].get(), 1, 0, 59)
        seconds = bounded_integer(duration_values[2].get(), 0, 0, 59)
        attempts_value = bounded_integer(attempts_input.get(), DEFAULT_DOWNLOAD_ATTEMPTS, 1, 10)
        try:
            delay = max(0, min(30, float(delay_input.get())))
        except ValueError:
            delay = 1
        settings.update({
            "default_duration_hours": hours,
            "default_duration_minutes": minutes,
            "default_duration_seconds": seconds,
            "download_attempts": attempts_value,
            "retry_delay_seconds": delay,
        })
        save_settings(settings)

    def close_settings():
        save_duration_and_retry_settings()
        dialog.destroy()

    make_neutral_button(frame, "Done", close_settings, width=10).grid(
        row=25, column=0, sticky="e"
    )
    place_on_screen(
        dialog,
        root.winfo_rootx() + (root.winfo_width() // 2),
        root.winfo_rooty() + (root.winfo_height() // 2),
    )
    dialog.deiconify()
    dialog.grab_set()


def version_key(version):
    """Convert a GitHub tag such as v1.2.0 into comparable numbers."""
    numbers = re.findall(r"\d+", str(version).lstrip("vV"))
    return tuple(int(number) for number in numbers) or (0,)


def latest_release():
    """Return the public latest GitHub release and its DMG download link."""
    request = urllib.request.Request(
        RELEASE_API_URL,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "BBCD4 update checker",
        },
    )
    with urllib.request.urlopen(request, timeout=8) as response:
        release = json.load(response)

    tag = str(release.get("tag_name", "")).strip()
    if not tag:
        raise RuntimeError("The latest release does not have a version tag.")
    dmg_url = next(
        (
            asset.get("browser_download_url")
            for asset in release.get("assets", [])
            if asset.get("name", "").lower().endswith(".dmg")
        ),
        None,
    )
    return {
        "version": tag.lstrip("vV"),
        "notes": str(release.get("body") or "No release notes were provided."),
        "download_url": dmg_url,
        "release_url": release.get("html_url"),
    }


update_info = None
update_banner = None


def apply_update_check(result, show_up_to_date=False):
    """Update the window after the background GitHub request finishes."""
    global update_info
    if isinstance(result, Exception):
        if show_up_to_date:
            messagebox.showwarning(
                "Could not check for updates",
                "BBCD4 could not reach GitHub right now. Please try again later.",
            )
        return

    update_info = result
    available = version_key(result["version"]) > version_key(APP_VERSION)
    if available:
        if update_banner is not None:
            update_banner.grid(row=0, column=6, sticky="e", padx=(0, 24), pady=(10, 3))
        if show_up_to_date:
            show_update_popover()
    else:
        if update_banner is not None:
            update_banner.grid_remove()
        if show_up_to_date:
            messagebox.showinfo("BBCD4 is up to date", f"You are using BBCD4 {APP_VERSION}.")


def check_for_updates(show_up_to_date=False):
    """Check GitHub without freezing the interface."""
    def check():
        try:
            result = latest_release()
        except (OSError, ValueError, urllib.error.URLError) as error:
            result = error
        root.after(0, lambda: apply_update_check(result, show_up_to_date))

    ThreadPoolExecutor(max_workers=1).submit(check)


def open_update_download():
    if not update_info:
        return
    url = update_info.get("download_url") or update_info.get("release_url")
    if not url:
        messagebox.showwarning(
            "Download unavailable",
            "This release does not include a DMG download yet.",
        )
        return
    try:
        subprocess.Popen(["open", url])
    except OSError as error:
        messagebox.showerror("Could not open download", str(error))


def show_update_popover():
    if not update_info or version_key(update_info["version"]) <= version_key(APP_VERSION):
        check_for_updates(show_up_to_date=True)
        return

    dialog = tk.Toplevel(root)
    dialog.withdraw()
    dialog.title("Update available")
    dialog.resizable(False, False)
    dialog.transient(root)
    frame = ttk.Frame(dialog, padding=14)
    frame.grid()
    ttk.Label(
        frame, text=f"BBCD4 {update_info['version']} is available", font=SECTION_TITLE_FONT
    ).grid(row=0, column=0, sticky="w", pady=(0, 8))
    ttk.Label(frame, text="What's new", font=FORM_LABEL_FONT).grid(
        row=1, column=0, sticky="w", pady=(0, 2)
    )
    ttk.Label(
        frame, text=update_info["notes"], justify="left", wraplength=430,
    ).grid(row=2, column=0, sticky="w", pady=(0, 12))
    buttons = ttk.Frame(frame)
    buttons.grid(row=3, column=0, sticky="e")
    make_neutral_button(buttons, "Later", dialog.destroy, width=10).pack(side="left", padx=(0, 8))
    make_blue_button(
        buttons, f"Download {update_info['version']}", open_update_download, width=16
    ).pack(side="left")
    place_on_screen(
        dialog,
        root.winfo_rootx() + (root.winfo_width() // 2),
        root.winfo_rooty() + (root.winfo_height() // 2),
    )
    dialog.deiconify()
    dialog.grab_set()


def delete_stream(name):
    if not name or name not in streams:
        messagebox.showwarning("No stream selected", "Select a saved stream to delete.")
        return False
    if not settings.get("skip_delete_confirmation", False):
        if not messagebox.askyesno("Delete stream", f"Delete the stream '{name}'?"):
            return False

    streams.pop(name)
    deleted_streams.add(name)
    stream_order.remove(name)
    save_streams(streams, deleted_streams, stream_order)
    return True


def show_stream_menu():
    """Manage your streams and add new ones."""
    global stream_popup
    if stream_popup is not None and stream_popup.winfo_exists():
        stream_popup.lift()
        stream_popup.focus_force()
        return

    popup = tk.Toplevel(root)
    popup.withdraw()
    stream_popup = popup
    popup.title("Stream management")
    popup.resizable(False, False)
    popup.transient(root)

    def close_popup():
        global stream_popup
        stream_popup = None
        popup.destroy()

    popup.protocol("WM_DELETE_WINDOW", close_popup)

    frame = ttk.Frame(popup, padding=8)
    frame.grid()
    frame.columnconfigure(0, weight=1)
    ttk.Label(frame, text="Your streams", font=STREAM_SECTION_FONT).grid(row=0, column=0, sticky="w")
    listbox = tk.Listbox(
        frame, width=34, height=min(20, max(1, len(stream_order))),
        exportselection=False,
    )
    listbox.grid(row=1, column=0, sticky="nsew", pady=(4, 6))
    scrollbar = ttk.Scrollbar(frame, orient="vertical", command=listbox.yview)
    scrollbar.grid(row=1, column=1, sticky="ns", pady=(4, 6))
    listbox.configure(yscrollcommand=scrollbar.set)

    def refresh_listbox(preferred_name=None):
        listbox.delete(0, tk.END)
        for stream_name in stream_order:
            listbox.insert(tk.END, stream_name)
        name_to_select = preferred_name or selected_stream.get()
        if name_to_select in stream_order:
            index = stream_order.index(name_to_select)
            listbox.selection_set(index)
            listbox.activate(index)
            listbox.see(index)

    refresh_listbox()
    drag_index = {"value": None, "moved": False}

    def select_current(event=None):
        chosen = listbox.curselection()
        if chosen:
            selected_stream.set(listbox.get(chosen[0]))
            refresh_stream_button()
            close_popup()

    def edit_current():
        chosen = listbox.curselection()
        if not chosen:
            messagebox.showwarning("No stream selected", "Select a stream to edit.")
            return

        old_name = listbox.get(chosen[0])
        editor = tk.Toplevel(popup)
        editor.withdraw()
        editor.title("Edit stream")
        editor.resizable(False, False)
        editor.transient(popup)

        edit_frame = ttk.Frame(editor, padding=12)
        edit_frame.grid()
        ttk.Label(edit_frame, text="Stream name", font=FORM_LABEL_FONT).grid(row=0, column=0, sticky="w")
        name_input = ttk.Entry(edit_frame, width=45)
        name_input.grid(row=1, column=0, sticky="ew", pady=(2, 8))
        name_input.insert(0, old_name)
        ttk.Label(edit_frame, text="Stream URL", font=FORM_LABEL_FONT).grid(row=2, column=0, sticky="w")
        url_input = ttk.Entry(edit_frame, width=70)
        url_input.grid(row=3, column=0, sticky="ew", pady=(2, 4))
        url_input.insert(0, streams[old_name])
        enable_drag_selection_scroll(url_input)

        button_row = ttk.Frame(edit_frame)
        button_row.grid(row=4, column=0, sticky="e", pady=(4, 0))

        def save_changes():
            new_stream_name = name_input.get().strip()
            new_stream_url = url_input.get().strip()
            if not new_stream_name or not new_stream_url:
                messagebox.showerror("Missing details", "Enter both a stream name and stream URL.", parent=editor)
                return
            if not is_supported_stream_url(new_stream_url):
                messagebox.showwarning(
                    "Invalid stream URL",
                    "Paste a full URL ending in .mpd or .m3u8.",
                    parent=editor,
                )
                url_input.focus_set()
                return
            if new_stream_name != old_name and new_stream_name in streams:
                messagebox.showerror("Name already used", "A saved stream already has that name. That's a little confusing, don't you think?", parent=editor)
                return
            index = stream_order.index(old_name)
            if new_stream_name != old_name:
                streams.pop(old_name)
                deleted_streams.add(old_name)
                deleted_streams.discard(new_stream_name)
                stream_order[index] = new_stream_name
            streams[new_stream_name] = new_stream_url
            save_streams(streams, deleted_streams, stream_order)
            selected_stream.set(new_stream_name)
            refresh_stream_button()
            refresh_listbox(new_stream_name)
            editor.destroy()

        make_blue_button(button_row, "Save", save_changes).pack(side="right")
        make_neutral_button(button_row, "Cancel", editor.destroy).pack(side="right", padx=(0, 6))
        editor.bind("<Return>", lambda event: (save_changes(), "break")[1])
        editor.bind("<KP_Enter>", lambda event: (save_changes(), "break")[1])
        bbox = listbox.bbox(chosen[0])
        preferred_x = listbox.winfo_rootx()
        preferred_y = listbox.winfo_rooty() + listbox.winfo_height()
        if bbox:
            preferred_y = listbox.winfo_rooty() + bbox[1] + bbox[3]
        place_on_screen(editor, preferred_x, preferred_y)
        editor.deiconify()
        editor.grab_set()
        name_input.focus_set()

    def delete_current(event=None):
        chosen = listbox.curselection()
        if not chosen:
            messagebox.showwarning("No stream selected", "Select a stream to delete.")
            return "break"
        deleted_index = chosen[0]
        deleted_name = listbox.get(deleted_index)
        if delete_stream(deleted_name):
        
            if stream_order:
                next_index = deleted_index - 1 if deleted_index > 0 else 0
                next_name = stream_order[next_index]
                selected_stream.set(next_name)
                refresh_stream_button()
                refresh_listbox(next_name)
                listbox.focus_set()
            else:
                selected_stream.set("")
                refresh_stream_button()
                refresh_listbox()
        return "break"

    def drag_start(event):
        drag_index["value"] = listbox.nearest(event.y)
        drag_index["moved"] = False

    def drag_move(event):
        if drag_index["value"] is None:
            return
        target = listbox.nearest(event.y)
        source = drag_index["value"]
        if target == source:
            return
        stream_order[source], stream_order[target] = stream_order[target], stream_order[source]
        refresh_listbox(stream_order[target])
        drag_index["value"] = target
        drag_index["moved"] = True

    def drag_end(event):
        if drag_index["moved"]:
            save_streams(streams, deleted_streams, stream_order)
            refresh_stream_button()
        drag_index["value"] = None

    context_menu = tk.Menu(popup, tearoff=False)
    context_menu.add_command(label="Edit stream", command=edit_current)
    context_menu.add_command(label="Delete stream", command=delete_current)

    def show_stream_context_menu(event):
        index = listbox.nearest(event.y)
        bbox = listbox.bbox(index)
        if not bbox or not bbox[1] <= event.y < bbox[1] + bbox[3]:
            return
        listbox.selection_clear(0, tk.END)
        listbox.selection_set(index)
        listbox.activate(index)
        context_menu.tk_popup(event.x_root, event.y_root)

    hint = tk.Label(
        frame, text="Drag to reorder. Double click to select a stream. Right click to edit or delete.",
        font=FORM_LABEL_FONT, fg="gray", bg=popup.cget("bg"), anchor="w",
    )
    hint.grid(row=2, column=0, columnspan=2, sticky="ew", pady=(2, 6))
    ttk.Separator(frame).grid(row=3, column=0, columnspan=2, sticky="ew", pady=(0, 8))
    ttk.Label(frame, text="Add new stream", font=STREAM_SECTION_FONT).grid(row=4, column=0, sticky="w")
    ttk.Label(frame, text="Stream name", font=FORM_LABEL_FONT).grid(row=5, column=0, sticky="w", pady=(4, 0))
    new_name = ttk.Entry(frame, width=34)
    new_name.grid(row=6, column=0, columnspan=2, sticky="ew", pady=(2, 5))
    ttk.Label(frame, text="Stream URL", font=FORM_LABEL_FONT).grid(row=7, column=0, sticky="w")
    new_url = ttk.Entry(frame, width=34)
    new_url.grid(row=8, column=0, columnspan=2, sticky="ew", pady=(2, 6))
    add_placeholder(new_name, "Choose a stream name (e.g. BBC World News Europe UHD)")
    add_placeholder(new_url, "Paste a stream URL (.mpd or .m3u8 only)")
    enable_drag_selection_scroll(new_url)

    def save_new_stream():
        if add_stream(new_name, new_url, refresh_listbox):
            listbox.focus_set()

    make_blue_button(frame, "Save Stream", save_new_stream, width=16).grid(row=9, column=0, sticky="w")

    place_on_screen(
        popup, stream_settings.winfo_rootx(),
        stream_settings.winfo_rooty() + stream_settings.winfo_height(),
    )
    popup.deiconify()

    listbox.bind("<Double-Button-1>", select_current)
    listbox.bind("<ButtonPress-1>", drag_start)
    listbox.bind("<B1-Motion>", drag_move)
    listbox.bind("<ButtonRelease-1>", drag_end)
    listbox.bind("<Button-2>", show_stream_context_menu)
    listbox.bind("<Button-3>", show_stream_context_menu)
    listbox.bind("<Control-Button-1>", show_stream_context_menu)
    listbox.bind("<BackSpace>", delete_current)
    listbox.bind("<Delete>", delete_current)


def change_stepper(entry, amount, minimum, maximum, step=1):
    try:
        value = float(entry.get())
    except ValueError:
        value = minimum
    value = max(minimum, min(maximum, value + amount * step))
    entry.delete(0, tk.END)
    if step == 1:
        entry.insert(0, str(int(value)))
    else:
        entry.insert(0, f"{value:.1f}")


def make_stepper_control(parent, initial, minimum, maximum, width=4, step=1, allow_decimal=False):
    """An entry with the same hold-to-repeat arrow control used on the main page."""
    controls = ttk.Frame(parent)
    validation = () if allow_decimal else (number_validator, "%P")
    entry = ttk.Entry(
        controls, width=width, justify="center", validate="key" if validation else "none",
        validatecommand=validation,
    )
    entry.grid(row=0, column=0, sticky="w")
    entry.insert(0, f"{initial:.1f}" if step != 1 else str(int(initial)))
    arrows = tk.Canvas(
        controls, width=14, height=20, bg="#F5F5F5",
        borderwidth=0, highlightthickness=0, cursor="",
    )
    arrows.grid(row=0, column=1, padx=0)
    arrows.create_text(7, 5, text="▲", font=("TkDefaultFont", 6), fill="#000000")
    arrows.create_text(7, 15, text="▼", font=("TkDefaultFont", 6), fill="#000000")
    repeat_job = {"id": None}

    def stop_repeating(event=None):
        if repeat_job["id"] is not None:
            arrows.after_cancel(repeat_job["id"])
            repeat_job["id"] = None

    def start_repeating(event):
        stop_repeating()
        amount = 1 if event.y < (arrows.winfo_height() // 2) else -1
        change_stepper(entry, amount, minimum, maximum, step)

        def repeat_step():
            change_stepper(entry, amount, minimum, maximum, step)
            repeat_job["id"] = arrows.after(75, repeat_step)

        repeat_job["id"] = arrows.after(350, repeat_step)

    arrows.bind("<ButtonPress-1>", start_repeating)
    arrows.bind("<ButtonRelease-1>", stop_repeating)
    arrows.bind("<Leave>", stop_repeating)
    return entry


def make_stepper(parent, label, initial, minimum, maximum):
    group = ttk.Frame(parent)
    group.pack(side="left", padx=(0, 6))
    entry = make_stepper_control(group, initial, minimum, maximum)
    entry.master.pack(anchor="w")
    ttk.Label(group, text=label, font=DURATION_LABEL_FONT).pack(anchor="w", pady=(2, 0))
    return entry


def add_placeholder(entry, text):
    entry.placeholder = text
    entry.insert(0, text)
    entry.configure(foreground="gray")

    def clear_placeholder(event):
        if entry.get() == text:
            entry.delete(0, tk.END)
            entry.configure(foreground="")

    entry.bind("<FocusIn>", clear_placeholder)
    entry.bind("<FocusOut>", lambda event: restore_placeholder(entry))


def restore_placeholder(entry):
    if not entry.get().strip():
        entry.insert(0, entry.placeholder)
        entry.configure(foreground="gray")


def make_blue_button(parent, text, command, width=None):
    """Create a consistently styled action button, including on macOS."""
    button = tk.Label(
        parent, text=text, width=width, padx=6, pady=5, anchor="center",
        bg=BUTTON_BLUE, fg="white", cursor="",
    )
    button.bind("<Enter>", lambda event: button.configure(bg=BUTTON_HOVER))
    button.bind("<Leave>", lambda event: button.configure(bg=BUTTON_BLUE))
    button.bind("<ButtonPress-1>", lambda event: button.configure(bg=BUTTON_HOVER))
    button.bind("<ButtonRelease-1>", lambda event: command())
    return button


def make_neutral_button(parent, text, command, width=None):
    """Create a white action button with the same dimensions as blue buttons."""
    button = tk.Label(
        parent, text=text, width=width, padx=6, pady=5, anchor="center",
        bg="#F5F5F5", fg="#000000", cursor="",
    )
    button.bind("<ButtonRelease-1>", lambda event: command())
    return button


def make_red_button(parent, text, command, width=None):
    """Create a red destructive-action button matching the other action buttons."""
    button = tk.Label(
        parent, text=text, width=width, padx=6, pady=5, anchor="center",
        bg="#D70015", fg="white", cursor="",
    )
    button.bind("<Enter>", lambda event: button.configure(bg="#FF5A5F"))
    button.bind("<Leave>", lambda event: button.configure(bg="#D70015"))
    button.bind("<ButtonRelease-1>", lambda event: command())
    return button


def make_icon_button(parent, icon, command):
    """A compact icon button that is no taller than its neighbouring entry."""
    normal_background = root.cget("bg")
    button = tk.Label(
        parent, text=icon, width=3, height=1, padx=0, pady=5,
        bg=normal_background, cursor="",
        relief="flat", borderwidth=0, highlightthickness=0,
    )
    button.bind("<Button-1>", lambda event: command())
    button.bind("<Enter>", lambda event: button.configure(bg="#303030"))
    button.bind("<Leave>", lambda event: button.configure(bg=normal_background))
    return button


class ToolTip:
    """A lightweight hover message for controls that benefit from explanation."""
    def __init__(self, widget, text):
        self.widget = widget
        self.text = text
        self.popup = None
        self.after_id = None
        widget.bind("<Enter>", self.schedule, add="+")
        widget.bind("<Leave>", self.hide, add="+")

    def schedule(self, event=None):
        self.after_id = self.widget.after(450, self.show)

    def show(self):
        self.after_id = None
        if self.popup or not self.widget.winfo_exists():
            return
        self.popup = tk.Toplevel(self.widget)
        self.popup.withdraw()
        self.popup.overrideredirect(True)
        self.popup.attributes("-topmost", True)
        tk.Label(
            self.popup, text=self.text, justify="left", padx=8, pady=5,
            bg="#303030", fg="white", relief="solid", borderwidth=1,
        ).pack()
        self.popup.geometry(
            f"+{self.widget.winfo_rootx()}+"
            f"{self.widget.winfo_rooty() + self.widget.winfo_height() + 4}"
        )
        self.popup.deiconify()

    def hide(self, event=None):
        if self.after_id:
            self.widget.after_cancel(self.after_id)
            self.after_id = None
        if self.popup:
            self.popup.destroy()
            self.popup = None


def allow_number_input(value):
    return not value or value.isdecimal()


def allow_date_input(value):
    return len(value) <= 20 and all(char.isalnum() or char in " -/.," for char in value)


def allow_time_input(value):
    return len(value) <= 8 and all(char.isdecimal() or char == ":" for char in value)


streams, deleted_streams, stream_order = load_streams()
settings = load_settings()
if settings.get("date_format") in LEGACY_DATE_FORMATS:
    settings["date_format"] = LEGACY_DATE_FORMATS[settings["date_format"]]
    save_settings(settings)
DOWNLOAD_DIR = get_download_dir(settings)
stream_popup = None

root = tk.Tk()
root.title("BBCD4")
root.resizable(False, False)

menu_bar = tk.Menu(root)
file_menu = tk.Menu(menu_bar, tearoff=False)
file_menu.add_command(label="Settings…", command=show_settings)
file_menu.add_command(label="Check for updates…", command=lambda: check_for_updates(show_up_to_date=True))
file_menu.add_separator()
file_menu.add_command(label="Quit BBCD4", command=root.destroy)
menu_bar.add_cascade(label="File", menu=file_menu)
root.configure(menu=menu_bar)

FORM_LABEL_FONT = ("TkDefaultFont", 11)
DURATION_LABEL_FONT = ("TkDefaultFont", 7)
SECTION_TITLE_FONT = ("TkDefaultFont", 16, "bold")
MAIN_TITLE_FONT = ("TkDefaultFont", 18, "bold")
STREAM_SECTION_FONT = ("TkDefaultFont", 12, "bold")
LABEL_PAD = (8, 12)
BUTTON_BLUE = "#0A84FF"
BUTTON_BLUE_DARK = "#006EDC"
BUTTON_HOVER = "#8A8A8A"

ttk.Label(root, text="Stream downloaderer IV", font=MAIN_TITLE_FONT).grid(
    row=0, column=0, sticky="w", padx=8, pady=(10, 3)
)

selected_stream = tk.StringVar(value=stream_order[0] if stream_order else "")
ttk.Label(root, text="Choose stream", font=FORM_LABEL_FONT).grid(row=1, column=0, sticky="w", padx=LABEL_PAD, pady=(0, 3))
stream_row = ttk.Frame(root)
stream_row.grid(row=2, column=0, columnspan=2, sticky="w", padx=8, pady=(0, 10))
stream_selector = ttk.Combobox(
    stream_row, textvariable=selected_stream, values=stream_order,
    width=30, state="readonly",
)
stream_selector.grid(row=0, column=0, sticky="w")
stream_settings = make_icon_button(stream_row, "⚙️", show_stream_menu)
stream_settings.grid(row=0, column=1, sticky="w", padx=(3, 0))
refresh_stream_button()

logo_image = tk.PhotoImage(file=os.path.join(SCRIPT_DIR, "bbcd4.png"))
logo_placeholder = tk.Label(
    root, image=logo_image, bg=root.cget("bg"), borderwidth=0,
    highlightthickness=0,
)
logo_placeholder.image = logo_image
logo_placeholder.grid(row=1, column=6, rowspan=6, sticky="e", padx=(0, 24), pady=0)

# Kept hidden until GitHub reports a release newer than this installed version.
update_banner = make_red_button(root, "Update!", show_update_popover, width=16)

schedule_controls = ttk.Frame(root)
schedule_controls.grid(row=3, column=0, columnspan=4, sticky="w", padx=8)
ttk.Label(schedule_controls, text="Start date", font=FORM_LABEL_FONT).grid(row=0, column=0, sticky="w", pady=(0, 3))
ttk.Label(schedule_controls, text="Start time", font=FORM_LABEL_FONT).grid(row=0, column=2, sticky="w", padx=(18, 0), pady=(0, 3))

number_validator = root.register(allow_number_input)
date_validator = root.register(allow_date_input)
time_validator = root.register(allow_time_input)

date_entry = ttk.Entry(
    schedule_controls, width=13, validate="key",
    validatecommand=(date_validator, "%P"),
)
date_entry.grid(row=1, column=0, sticky="w", pady=(0, 10))
date_entry.insert(0, format_display_date(datetime.now()))

make_icon_button(schedule_controls, "📅", choose_date).grid(
    row=1, column=1, sticky="w", padx=(2, 0), pady=(0, 10)
)

time_values = [f"{hour:02d}:{minute:02d}:00" for hour in range(24) for minute in (0, 30)]
time_choice = ttk.Combobox(
    schedule_controls, values=time_values, width=10, validate="key",
    validatecommand=(time_validator, "%P"),
)
time_choice.grid(row=1, column=2, sticky="w", padx=(18, 0), pady=(0, 10))
time_choice.set(datetime.now().strftime("%H:%M:%S"))

ttk.Label(root, text="Duration", font=FORM_LABEL_FONT).grid(row=4, column=0, sticky="w", padx=LABEL_PAD, pady=(0, 3))

duration_controls = ttk.Frame(root)
duration_controls.grid(row=5, column=0, columnspan=4, sticky="w", padx=8)
default_hours, default_minutes, default_seconds = default_duration_values()
hours_spinbox = make_stepper(duration_controls, "Hours", default_hours, 0, 350)
minutes_spinbox = make_stepper(duration_controls, "Minutes", default_minutes, 0, 59)
seconds_spinbox = make_stepper(duration_controls, "Seconds", default_seconds, 0, 59)

download_row = ttk.Frame(root)
download_row.grid(row=6, column=0, columnspan=7, sticky="w", padx=8, pady=(10, 10))
make_blue_button(download_row, "Download", run_download, width=16).pack(side="left")
encode_h265 = tk.BooleanVar(value=bool(settings.get("encode_h265", False)))
encode_checkbox = ttk.Checkbutton(
    download_row,
    text="Encode to H.265",
    variable=encode_h265,
    command=remember_encode_choice,
)
encode_checkbox.pack(side="left", padx=(12, 0))
ToolTip(
    encode_checkbox,
    "Encodes video for better compatability with Apple devices\nThis may take a long time depending on video length",
)

status = tk.StringVar(value="Ready")
save_location = tk.StringVar()
update_save_location()

ttk.Label(root, textvariable=status).grid(
    row=7,
    column=0,
    columnspan=3,
    sticky="w",
    padx=8,
    pady=5
)
save_location_frame = ttk.Frame(root)
save_location_frame.grid(
    row=7,
    column=3,
    columnspan=4,
    sticky="e",
    padx=8,
    pady=5
)
ttk.Label(save_location_frame, textvariable=save_location).pack(side="left")
change_location_link = ttk.Label(
    save_location_frame, text="Change", foreground=BUTTON_BLUE,
)
change_location_link.pack(side="left", padx=(4, 0))
change_location_link.bind("<Button-1>", choose_download_folder)
change_location_link.bind("<Enter>", lambda event: change_location_link.configure(foreground="#5BA7FF"))
change_location_link.bind("<Leave>", lambda event: change_location_link.configure(foreground=BUTTON_BLUE))

discord_icon = tk.PhotoImage(file=os.path.join(SCRIPT_DIR, "Discord-Symbol-White.png"))
discord_button = tk.Label(
    root, image=discord_icon, bg=root.cget("bg"), padx=5, pady=5,
    cursor="", borderwidth=0, highlightthickness=0,
)
discord_button.image = discord_icon
discord_button.grid(row=6, column=6, sticky="e", padx=(0, 24), pady=(10, 10))
discord_button.bind("<Button-1>", lambda event: open_discord_invite())
discord_button.bind("<Enter>", lambda event: discord_button.configure(bg="#303030"))
discord_button.bind("<Leave>", lambda event: discord_button.configure(bg=root.cget("bg")))

progress = ttk.Progressbar(root, mode="determinate", length=430)
progress.grid(row=8, column=0, columnspan=7, sticky="ew", padx=8, pady=(0, 10))

if settings.get("check_updates_on_launch", True):
    root.after(500, check_for_updates)

root.mainloop()
