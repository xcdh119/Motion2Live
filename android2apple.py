#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
android2apple.py — 把安卓动态照片（OPPO / vivo / Google 单文件，或 JPEG+MP4 双文件）
无损转换成苹果实况照片（JPEG + MOV 配对）；其他图片和独立视频可扫描分类。

原理：
  * 单文件（OPPO 等）：JPEG 末尾追加了原始 MOV。按 OpCamera:VideoLength 切出视频，
    JPEG 部分保持原样。
  * 双文件（vivo 等）：JPEG + MP4 直接配对。
  * 苹果“实况”的判定只看两端是否写入同一个 ContentIdentifier：
      - 视频：com.apple.quicktime.content.identifier（QuickTime keys 元数据）
      - 静态图：Apple MakerNote 的 0x0011 标签
    本脚本把视频里已有的 ID 原样写进仍缺 ID 的 JPEG；视频本来就有 ID 时完全不碰视频。
  * 写 MakerNote 只改 JPEG 的 Exif APP1 段（有空白就原地写，没空白就整段后移 69 字节），
    图像扫描数据、MPF/Ultra HDR 增益图、EXIF 日期和方向都不重新编码。

依赖：
  * Python 3.9+
  * ffmpeg / ffprobe（PATH 中，或设置 FFMPEG / FFPROBE）
  * exiftool（仅在需要给视频补 ID 时用到；PATH 中，或设置 EXIFTOOL）

用法：
  python3 android2apple.py <文件或文件夹> [...] -o output
  python3 android2apple.py ~/Downloads/Photos -o output

输出：
  <原名>.jpg + <原名>.mov，成对放在输出目录。原文件不会被修改。
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import traceback
import tempfile
import uuid

UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

def _resolve_tool(env_key, name, extra=()):
    val = os.environ.get(env_key)
    if val:
        return val
    found = shutil.which(name)
    if found:
        return found
    for candidate in extra:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"):
        candidate = os.path.join(prefix, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return name


_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EXIFTOOL = _resolve_tool("EXIFTOOL", "exiftool", (
    os.path.join(_SCRIPT_DIR, "exiftool", "exiftool"),
    os.path.join(_SCRIPT_DIR, "app", "vendor", "exiftool", "exiftool"),
))
FFMPEG = _resolve_tool("FFMPEG", "ffmpeg")
FFPROBE = _resolve_tool("FFPROBE", "ffprobe")

JPEG_EXTS = (".jpg", ".jpeg")
IMAGE_EXTS = JPEG_EXTS + tuple("." + e for e in ("png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp", "avif"))
VIDEO_EXTS = (".mp4", ".mov", ".m4v", ".avi", ".mkv", ".3gp", ".mts", ".m2ts")


def run(cmd, check=True):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode != 0:
        raise RuntimeError("%s\n%s" % (" ".join(cmd), p.stderr.decode("utf-8", "replace").strip()))
    return p


def have(cmd):
    return shutil.which(cmd) is not None


def u16(d, off, en):
    return struct.unpack(en + "H", d[off:off + 2])[0]


def u32(d, off, en):
    return struct.unpack(en + "I", d[off:off + 4])[0]


def jpeg_segments(d):
    """Yield (offset, marker, length) for the leading JPEG segments."""
    p = 2
    while p + 4 <= len(d):
        if d[p] != 0xFF:
            return
        m = d[p + 1]
        if m == 0xD8 or m == 0xD9 or 0xD0 <= m <= 0xD7:
            p += 2
            continue
        ln = struct.unpack(">H", d[p + 2:p + 4])[0]
        yield p, m, ln
        if m == 0xDA:  # SOS: image data starts
            return
        p += 2 + ln


def find_appended_video(d):
    """Return the offset where a JPEG-appended MP4/MOV starts, or None."""
    pos = d.rfind(b"ftyp")
    while pos >= 4:
        start = pos - 4
        size = struct.unpack(">I", d[start:pos])[0]
        brand = d[pos + 4:pos + 8]
        if brand[:2] == b"qt" or brand in (b"mp42", b"mp41", b"isom", b"msnv"):
            # ftyp 后必须紧跟一个正常的顶层 box；不要求它紧贴 JPEG 的 EOI，
            # 因为部分机型会在 EOI 后还带 MPF/填充数据。
            if 16 <= size <= 64 and start + size + 8 <= len(d):
                ntyp = d[start + size + 4:start + size + 8]
                if ntyp in (b"moov", b"mdat", b"free", b"wide", b"uuid", b"pdin", b"skip"):
                    return start
        pos = d.rfind(b"ftyp", 0, pos)
    return None


def motion_video_length(d, start):
    """Best-effort length of the appended video."""
    m = re.search(rb'OpCamera:VideoLength="(\d+)"', d)
    if m:
        n = int(m.group(1))
        if 0 < n <= len(d) - start:
            return n
    # Google Motion Photo: video length is usually to EOF
    return len(d) - start


def read_video_uuid(path):
    p = run([FFPROBE, "-v", "error", "-show_entries",
             "format_tags=com.apple.quicktime.content.identifier",
             "-of", "default=nw=1:nk=1", path], check=False)
    v = p.stdout.decode("utf-8", "replace").strip()
    return v if UUID_RE.match(v) else None


def write_video_uuid(path, value):
    if not have(EXIFTOOL):
        raise RuntimeError("需要 exiftool 给视频补 ContentIdentifier；请先 brew install exiftool")
    run([EXIFTOOL, "-overwrite_original", "-Keys:ContentIdentifier=%s" % value, path])


def build_makernote(value):
    """Apple MakerNote: 'Apple iOS\\0\\x00\\x01MM' + one IFD entry 0x0011."""
    mn = b"Apple iOS\x00" + b"\x00\x01MM"
    mn += struct.pack(">H", 1)
    mn += struct.pack(">HHI", 0x0011, 2, 37)
    mn += struct.pack(">I", 32)
    mn += struct.pack(">I", 0)
    mn += value.encode("ascii") + b"\x00"
    assert len(mn) == 69
    return mn


def find_tag(d, tiff, en, ifd_rel, tag_wanted):
    n = u16(d, tiff + ifd_rel, en)
    for i in range(n):
        o = tiff + ifd_rel + 2 + i * 12
        if u16(d, o, en) == tag_wanted:
            return o
    return None


def walk_end(d, tiff, en, ifd_rel, seen):
    """Max end offset (relative to TIFF) referenced by an IFD chain."""
    if ifd_rel in seen or ifd_rel <= 0 or tiff + ifd_rel + 2 > len(d):
        return 0
    seen.add(ifd_rel)
    n = u16(d, tiff + ifd_rel, en)
    end = ifd_rel + 2 + n * 12 + 4
    for i in range(n):
        o = tiff + ifd_rel + 2 + i * 12
        tag = u16(d, o, en)
        typ = u16(d, o + 2, en)
        cnt = u32(d, o + 4, en)
        val = u32(d, o + 8, en)
        size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4,
                10: 8, 11: 4, 12: 8}.get(typ, 1) * cnt
        if size > 4:
            end = max(end, val + size)
        if tag in (0x8769, 0x8825, 0xA005):
            end = max(end, walk_end(d, tiff, en, val, seen))
    nxt = u32(d, tiff + ifd_rel + 2 + n * 12, en)
    if nxt:
        end = max(end, walk_end(d, tiff, en, nxt, seen))
    return end


def add_makernote(still, value):
    """Add a MakerNote entry + Apple MakerNote when the Exif IFD has none.

    The old ExifIFD is left orphaned; a copy with one extra entry (0x927C)
    is appended together with the MakerNote, and IFD0's 0x8769 pointer is
    repointed. Existing data offsets stay valid; the APP1 segment grows.
    """
    d = bytearray(still)
    app1 = None
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            app1 = (p, ln)
            break
    if not app1:
        raise RuntimeError("JPEG 没有 Exif APP1 段")

    astart, alen = app1
    tiff = astart + 10
    en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
    ifd0 = u32(d, tiff + 4, en)
    exif_entry = find_tag(d, tiff, en, ifd0, 0x8769)
    if exif_entry is None:
        raise RuntimeError("Exif 里没有 ExifIFD")
    exif_ifd = u32(d, exif_entry + 8, en)

    n = u16(d, tiff + exif_ifd, en)
    entries = []
    for i in range(n):
        o = tiff + exif_ifd + 2 + i * 12
        entries.append((u16(d, o, en), u16(d, o + 2, en),
                        u32(d, o + 4, en), u32(d, o + 8, en)))
    next_ifd = u32(d, tiff + exif_ifd + 2 + n * 12, en)

    mn = build_makernote(value)
    payload_start = astart + 4
    payload_end = astart + 2 + alen
    new_ifd_rel = payload_end - tiff
    ifd_size = 2 + (n + 1) * 12 + 4
    new_mn_rel = new_ifd_rel + ifd_size

    new_ifd = bytearray()
    new_ifd += struct.pack(en + "H", n + 1)
    for tag, typ, cnt, val in entries:
        new_ifd += struct.pack(en + "HHI", tag, typ, cnt)
        new_ifd += struct.pack(en + "I", val)
    new_ifd += struct.pack(en + "HHI", 0x927C, 7, len(mn))
    new_ifd += struct.pack(en + "I", new_mn_rel)
    new_ifd += struct.pack(en + "I", next_ifd)

    d[exif_entry + 8:exif_entry + 12] = struct.pack(en + "I", new_ifd_rel)

    old_payload = bytes(d[payload_start:payload_end])
    new_len = alen + len(new_ifd) + len(mn)
    out = bytearray(bytes(d[:payload_start]) + old_payload +
                    bytes(new_ifd) + mn + bytes(d[payload_end:]))
    out[astart + 2:astart + 4] = struct.pack(">H", new_len)
    return bytes(out)


def patch_still(still, value):
    """Write the Apple ContentIdentifier into a JPEG without re-encoding it."""
    if not UUID_RE.match(value):
        raise ValueError("bad uuid")
    d = bytearray(still)

    app1 = None
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            app1 = (p, ln)
            break
    if not app1:
        if not still.startswith(b"\xff\xd8"):
            raise RuntimeError("文件不是有效的 JPEG")
        # Third-party exports can strip all EXIF. Build only the pairing metadata;
        # leave every existing JPEG segment and compressed image byte untouched.
        mn = build_makernote(value)
        tiff = b"II" + struct.pack("<HI", 42, 8)
        tiff += struct.pack("<H", 1) + struct.pack("<HHII", 0x8769, 4, 1, 26) + struct.pack("<I", 0)
        tiff += struct.pack("<H", 1) + struct.pack("<HHII", 0x927C, 7, len(mn), 44) + struct.pack("<I", 0)
        payload = b"Exif\x00\x00" + tiff + mn
        segment = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload
        return still[:2] + segment + still[2:]

    astart, alen = app1
    tiff = astart + 10                       # 4 (marker+len) + 6 (Exif\0\0)
    en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
    ifd0 = u32(d, tiff + 4, en)

    exif_entry = find_tag(d, tiff, en, ifd0, 0x8769)
    if exif_entry is None:
        raise RuntimeError("Exif 里没有 ExifIFD")
    exif_ifd = u32(d, exif_entry + 8, en)

    mn_entry = find_tag(d, tiff, en, exif_ifd, 0x927C)
    if mn_entry is None:
        return add_makernote(still, value)

    used = walk_end(d, tiff, en, ifd0, set())
    payload_start = astart + 4
    payload_end = astart + 2 + alen
    mn = build_makernote(value)

    if payload_end - (tiff + used) >= len(mn) + 1:
        # 有空白：原地写，文件长度不变，MPF 绝对偏移全部不受影响
        off = used + (used & 1)
        d[tiff + off:tiff + off + len(mn)] = mn
        new_len = alen
    else:
        # 没空白：在 APP1 末尾插入，段长增加；TIFF 里已有数据位置不变
        off = payload_end - tiff
        new_payload = bytes(d[payload_start:payload_end]) + mn
        d = bytearray(bytes(d[:payload_start]) + new_payload + bytes(d[payload_end:]))
        new_len = alen + len(mn)
        d[astart + 2:astart + 4] = struct.pack(">H", new_len)

    # 更新 MakerNote 入口（位于插入点之前，位置不变）
    d[mn_entry:mn_entry + 12] = (
        struct.pack(en + "HHI", 0x927C, 7, len(mn)) + struct.pack(en + "I", off)
    )
    return bytes(d)


def read_still_uuid(path):
    """Read Apple ContentIdentifier from the still using a tiny Exif walk."""
    with open(path, "rb") as stream:
        d = stream.read()
    app1 = None
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            app1 = (p, ln)
            break
    if not app1:
        return None
    astart, alen = app1
    tiff = astart + 10
    en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
    ifd0 = u32(d, tiff + 4, en)
    e = find_tag(d, tiff, en, ifd0, 0x8769)
    if e is None:
        return None
    exif_ifd = u32(d, e + 8, en)
    mn = find_tag(d, tiff, en, exif_ifd, 0x927C)
    if mn is None:
        return None
    mn_off = u32(d, mn + 8, en)
    mn_len = u32(d, mn + 4, en)
    blob = d[tiff + mn_off:tiff + mn_off + mn_len]
    if not blob.startswith(b"Apple iOS\x00"):
        return None
    # MakerNote's own IFD is at +14, offsets relative to the MakerNote start.
    try:
        n = struct.unpack(">H", blob[14:16])[0]
        for i in range(n):
            o = 14 + 2 + i * 12
            tag = struct.unpack(">H", blob[o:o + 2])[0]
            if tag == 0x0011:
                typ, cnt = struct.unpack(">HI", blob[o + 2:o + 8])
                val = struct.unpack(">I", blob[o + 8:o + 12])[0]
                s = blob[val:val + cnt].split(b"\x00")[0].decode("ascii", "replace")
                return s if UUID_RE.match(s) else None
    except Exception:
        return None
    return None


def video_brand(path):
    with open(path, "rb") as f:
        head = f.read(12)
    return head[8:12] if len(head) >= 12 else b""


def remux_to_mov(src, dst):
    # HEVC exported by third-party apps is often tagged hev1. Photos previews
    # it but can reject the pair on import; hvc1 fixes the sample entry losslessly.
    probe = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=codec_name", "-of", "csv=p=0", src], check=False)
    hevc = probe.stdout.decode("utf-8", "replace").strip() == "hevc"
    args = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src,
            "-c", "copy", "-map", "0"]
    if hevc:
        args += ["-tag:v:0", "hvc1"]
    run(args + [dst])


def _exif_entries(d):
    """Return (tiff, endian, {tag: (type, count, value, entry_offset)})."""
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            tiff = p + 10
            en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
            tags = {}
            try:
                ifd0 = u32(d, tiff + 4, en)
                def walk(rel):
                    n = u16(d, tiff + rel, en)
                    for i in range(n):
                        o = tiff + rel + 2 + i * 12
                        tag = u16(d, o, en)
                        typ = u16(d, o + 2, en)
                        cnt = u32(d, o + 4, en)
                        val = u32(d, o + 8, en)
                        tags[tag] = (typ, cnt, val, o)
                    return n
                walk(ifd0)
                if 0x8769 in tags:
                    walk(tags[0x8769][2])
                if 0x8825 in tags:
                    walk(tags[0x8825][2])
                return tiff, en, tags
            except Exception:
                return None
    return None


def _entry_ascii(d, tiff, item):
    typ, cnt, val, o = item
    try:
        raw = d[tiff + val:tiff + val + cnt] if cnt > 4 else d[o + 8:o + 8 + cnt]
        return raw.split(b"\x00")[0].decode("ascii", "replace").strip()
    except Exception:
        return ""


def read_capture_date(d):
    """Best capture date from EXIF: (date string with offset, unix timestamp)."""
    parsed = _exif_entries(d)
    if not parsed:
        return None
    tiff, en, tags = parsed
    date = ""
    for tag in (0x9003, 0x9004, 0x0132):
        if tag in tags:
            value = _entry_ascii(d, tiff, tags[tag])
            if re.match(r"\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}", value):
                date = value
                break
    if not date:
        return None

    offset = ""
    for tag in (0x9011, 0x9012):
        if tag in tags:
            value = _entry_ascii(d, tiff, tags[tag])
            if re.match(r"[+-]\d{2}:\d{2}", value):
                offset = value
                break
    if not offset:
        local = datetime.datetime.now().astimezone().strftime("%z")
        offset = local[:3] + ":" + local[3:] if local else "+00:00"

    try:
        dt = datetime.datetime.strptime(date, "%Y:%m:%d %H:%M:%S")
        sign = 1 if offset[0] == "+" else -1
        hours = int(offset[1:3])
        minutes = int(offset[4:6])
        tz = datetime.timezone(datetime.timedelta(hours=sign * hours, minutes=sign * minutes))
        ts = dt.replace(tzinfo=tz).timestamp()
        return date + offset, ts
    except Exception:
        return None


def _capture_date_from_tool(tags):
    """Use embedded capture/create tags, never the migration-time filesystem date."""
    if not isinstance(tags, dict):
        return None
    for key in ("DateTimeOriginal", "CreationDate", "CreateDate", "DateCreated", "MediaCreateDate", "TrackCreateDate"):
        value = tags.get(key)
        if not value:
            continue
        m = re.match(r"^(\d{4}[:-]\d{2}[:-]\d{2}[ T]\d{2}:\d{2}:\d{2})(?:\.\d+)?([+-]\d{2}:?\d{2}|Z)?", str(value).strip())
        if not m:
            continue
        date, offset = m.groups()
        date = date[:10].replace("-", ":") + " " + date[11:]
        offset = offset or tags.get("OffsetTimeOriginal") or tags.get("OffsetTime") or ""
        if offset == "Z": offset = "+00:00"
        if re.match(r"^[+-]\d{4}$", offset): offset = offset[:3] + ":" + offset[3:]
        try:
            dt = datetime.datetime.strptime(date, "%Y:%m:%d %H:%M:%S")
            if dt.year < 1900:
                continue
            if offset:
                sign = 1 if offset[0] == "+" else -1
                tz = datetime.timezone(datetime.timedelta(hours=sign * int(offset[1:3]), minutes=sign * int(offset[4:6])))
                dt = dt.replace(tzinfo=tz)
            else:
                # Localize at capture date, preserving historical daylight saving rules.
                dt = dt.astimezone()
                local = dt.strftime("%z")
                offset = local[:3] + ":" + local[3:]
            return date + offset, dt.timestamp()
        except (ValueError, TypeError, OverflowError):
            continue
    return None


def capture_date_from_filename(path):
    """Only explicit camera timestamp names, never arbitrary numeric IDs or file dates."""
    name = os.path.basename(path)
    m = re.match(r"^(?:IMG|VID|PXL|Screenshot)[_-](\d{8})[_-](\d{6})(?:[_.(]|$)", name, re.I)
    try:
        if m:
            dt = datetime.datetime.strptime("".join(m.groups()), "%Y%m%d%H%M%S").astimezone()
        else:
            m = re.match(r"^wx_camera_(\d{13})(?:[.(]|$)", name, re.I)
            if not m:
                return None
            dt = datetime.datetime.fromtimestamp(int(m.group(1)) / 1000).astimezone()
        if not 2000 <= dt.year <= datetime.datetime.now().year:
            return None
        offset = dt.strftime("%z")
        return dt.strftime("%Y:%m:%d %H:%M:%S") + offset[:3] + ":" + offset[3:], dt.timestamp()
    except (ValueError, OverflowError, OSError):
        return None


def _exiftool_available():
    if os.path.isfile(EXIFTOOL) and os.access(EXIFTOOL, os.X_OK):
        return True
    return shutil.which(EXIFTOOL) is not None


def apply_dates(path, date_str, ts, is_video=False):
    """Set file birth/modify dates (and video creation date) to the capture date."""
    if ts is None:
        return
    os.utime(path, (ts, ts))
    if not _exiftool_available():
        if os.path.exists("/usr/bin/SetFile"):
            try:
                dt = datetime.datetime.fromtimestamp(ts)
                subprocess.run(["/usr/bin/SetFile", "-d",
                                dt.strftime("%m/%d/%Y %H:%M:%S"), path],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            except Exception:
                pass
        return

    args = [EXIFTOOL, "-overwrite_original",
            "-FileCreateDate=" + date_str,
            "-FileModifyDate=" + date_str]
    if is_video:
        args += ["-Keys:CreationDate=" + date_str,
                 "-QuickTime:CreateDate=" + date_str]
    args.append(path)
    run(args, check=False)


def convert_one(still_path, video_path, out_dir, embedded_video=None, base=None, still_bytes=None, capture=None):
    """still_path: JPEG; video_path: str or None; embedded_video: bytes or None."""
    base = base or os.path.splitext(os.path.basename(still_path))[0]
    out_jpg = os.path.join(out_dir, base + ".jpg")
    out_mov = os.path.join(out_dir, base + ".mov")

    if still_bytes is not None:
        still = still_bytes
    else:
        with open(still_path, "rb") as stream:
            still = stream.read()
    capture = capture or read_capture_date(still)

    if embedded_video is not None:
        video_bytes = embedded_video
        tmp_video = os.path.join(out_dir, "." + base + ".tmp.mov")
        with open(tmp_video, "wb") as f:
            f.write(video_bytes)
        if video_brand(tmp_video) != b"qt  ":
            remuxed = tmp_video + ".remux.mov"
            remux_to_mov(tmp_video, remuxed)
            os.replace(remuxed, tmp_video)
    else:
        tmp_video = os.path.join(out_dir, "." + base + ".tmp.mov")
        if video_path.lower().endswith((".mp4", ".m4v")):
            remux_to_mov(video_path, tmp_video)
        else:
            probe = run([FFPROBE, "-v", "error", "-select_streams", "v:0",
                         "-show_entries", "stream=codec_tag_string", "-of", "csv=p=0", video_path], check=False)
            if probe.stdout.decode("utf-8", "replace").strip() == "hev1":
                remux_to_mov(video_path, tmp_video)
            else:
                shutil.copy2(video_path, tmp_video)

    value = read_video_uuid(tmp_video)
    if not value:
        value = str(uuid.uuid4()).upper()
        write_video_uuid(tmp_video, value)
        value = read_video_uuid(tmp_video) or value

    patched = patch_still(still, value)
    with open(out_jpg, "wb") as f:
        f.write(patched)
    shutil.move(tmp_video, out_mov)

    # Use the camera's capture time for file dates, not the migration time.
    if capture:
        apply_dates(out_jpg, capture[0], capture[1], is_video=False)
        apply_dates(out_mov, capture[0], capture[1], is_video=True)
    else:
        try:
            st = os.stat(still_path)
            os.utime(out_jpg, (st.st_atime, st.st_mtime))
            if video_path:
                st2 = os.stat(video_path)
                os.utime(out_mov, (st2.st_atime, st2.st_mtime))
        except OSError:
            pass

    got = read_still_uuid(out_jpg)
    if got != value:
        raise RuntimeError("校验失败：still=%s video=%s" % (got, value))
    return value


def jpeg_make(d):
    """Best-effort EXIF Make (for the UI badge)."""
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            tiff = p + 10
            en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
            try:
                ifd0 = u32(d, tiff + 4, en)
                n = u16(d, tiff + ifd0, en)
                for i in range(n):
                    o = tiff + ifd0 + 2 + i * 12
                    tag = u16(d, o, en)
                    typ = u16(d, o + 2, en)
                    cnt = u32(d, o + 4, en)
                    val = u32(d, o + 8, en)
                    if tag == 0x010F:
                        raw = d[tiff + val:tiff + val + cnt] if cnt > 4 else d[o + 8:o + 8 + cnt]
                        return raw.split(b"\x00")[0].decode("utf-8", "replace").strip()
            except Exception:
                pass
            break
    return ""


def jpeg_model(d):
    for p, m, ln in jpeg_segments(d):
        if m == 0xE1 and d[p + 4:p + 10] == b"Exif\x00\x00":
            tiff = p + 10
            en = ">" if d[tiff:tiff + 2] == b"MM" else "<"
            try:
                ifd0 = u32(d, tiff + 4, en)
                n = u16(d, tiff + ifd0, en)
                for i in range(n):
                    o = tiff + ifd0 + 2 + i * 12
                    tag = u16(d, o, en)
                    cnt = u32(d, o + 4, en)
                    val = u32(d, o + 8, en)
                    if tag == 0x0110:
                        raw = d[tiff + val:tiff + val + cnt] if cnt > 4 else d[o + 8:o + 8 + cnt]
                        return raw.split(b"\x00")[0].decode("utf-8", "replace").strip()
            except Exception:
                pass
            break
    return ""


def read_gps(d):
    parsed = _exif_entries(d)
    if not parsed:
        return None
    tiff, en, tags = parsed
    if 0x0002 not in tags or 0x0004 not in tags:
        return None

    def dms(item):
        typ, cnt, val, o = item
        base = tiff + val
        values = []
        for i in range(3):
            num = struct.unpack(en + "I", d[base + i * 8:base + i * 8 + 4])[0]
            den = struct.unpack(en + "I", d[base + i * 8 + 4:base + i * 8 + 8])[0]
            values.append(num / den if den else 0.0)
        return values[0] + values[1] / 60.0 + values[2] / 3600.0

    try:
        lat = dms(tags[0x0002])
        lon = dms(tags[0x0004])
        lat_ref = _entry_ascii(d, tiff, tags[0x0001]) if 0x0001 in tags else "N"
        lon_ref = _entry_ascii(d, tiff, tags[0x0003]) if 0x0003 in tags else "E"
        if lat_ref.upper().startswith("S"):
            lat = -lat
        if lon_ref.upper().startswith("W"):
            lon = -lon
        return round(lat, 7), round(lon, 7)
    except Exception:
        return None


def detect_hdr(d):
    head = d[:1024 * 1024]
    if b"hdrgm:Version" in head:
        return "Ultra HDR"
    if b"MPF\x00" in head:
        return "HDR 增益图"
    return "SDR"


def detect_live_type(make):
    m = (make or "").upper()
    if "APPLE" in m: return "Apple 实况"
    if "VIVO" in m: return "vivo 实况"
    if "OPPO" in m: return "OPPO 实况"
    if "ONEPLUS" in m: return "OnePlus 实况"
    if "XIAOMI" in m or "REDMI" in m: return "小米实况"
    if "HONOR" in m: return "荣耀实况"
    if "HUAWEI" in m: return "华为实况"
    if "SAMSUNG" in m: return "三星实况"
    return "实况"


def identical_media(first, second, hashes):
    """Numbered filenames alone never prove that a video is a Live Photo duplicate."""
    try:
        if os.path.getsize(first) != os.path.getsize(second):
            return False
        for path in (first, second):
            if path not in hashes:
                digest = hashlib.sha256()
                with open(path, "rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                hashes[path] = digest.digest()
        return hashes[first] == hashes[second]
    except OSError:
        return False


def collect_jobs(inputs, fast=False):
    files = []
    for item in inputs:
        if os.path.isdir(item):
            basename = os.path.basename(os.path.normpath(item))
            explicit_archive = basename in ("已转换原片", "非实况照片") or basename.startswith("已批量处理_")
            for root, dirs, names in os.walk(item):
                # Exclude only app-managed archives during recursive scans.
                if not explicit_archive:
                    dirs[:] = [d for d in dirs if d not in ("已转换原片", "非实况照片")
                               and not d.startswith("已批量处理_")
                               and not (d in ("实况", "待补写拍摄时间")
                                        and os.path.isdir(os.path.join(root, d, "原片")))
                               and not (d == "待补写拍摄时间"
                                        and os.path.isdir(os.path.join(root, d, "实况", "原片")))]
                for n in names:
                    files.append(os.path.join(root, n))
        elif os.path.isfile(item):
            files.append(item)

    files = list(dict.fromkeys(os.path.abspath(f) for f in files))
    by_dir = {}
    for f in files:
        by_dir.setdefault(os.path.dirname(os.path.abspath(f)), []).append(f)

    tool_dates = {}
    tool_metadata = {}
    if _exiftool_available() and files:
        # Bound command size for large imports and read metadata without touching sources.
        media_files = list(dict.fromkeys(os.path.abspath(f) for f in files
                     if os.path.splitext(f)[1].lower() in IMAGE_EXTS + VIDEO_EXTS))
        for offset in range(0, len(media_files), 100):
            p = run([EXIFTOOL, "-json", "-n", "-api", "QuickTimeUTC=1",
                     "-DateTimeOriginal", "-CreationDate", "-CreateDate", "-DateCreated",
                     "-MediaCreateDate", "-TrackCreateDate", "-OffsetTimeOriginal", "-OffsetTime",
                     "-Make", "-Model", "-GPSLatitude", "-GPSLongitude"] + media_files[offset:offset + 100], check=False)
            try:
                for obj in json.loads(p.stdout.decode("utf-8", "replace")):
                    path = os.path.abspath(obj.get("SourceFile", ""))
                    tool_metadata[path] = obj
                    tool_dates[path] = _capture_date_from_tool(obj)
            except (ValueError, TypeError):
                pass

    jobs = []
    companions = {}
    hashes = {}
    for d, fs in by_dir.items():
        videos = {}
        for f in sorted(fs):
            stem, ext = os.path.splitext(f)
            if ext.lower() in (".mp4", ".mov", ".m4v"):
                videos.setdefault(stem, f)
        # 显式只传 JPEG 时，也去同目录找同名视频
        for f in fs:
            stem, ext = os.path.splitext(f)
            if ext.lower() in JPEG_EXTS and stem not in videos:
                for ve in (".mov", ".MOV", ".mp4", ".MP4", ".m4v", ".M4V"):
                    cand = stem + ve
                    if os.path.exists(cand):
                        videos[stem] = cand
                        break

        image_stems = {os.path.splitext(f)[0] for f in fs
                       if os.path.splitext(f)[1].lower() in JPEG_EXTS}
        paired_video_paths = {video for stem, video in videos.items() if stem in image_stems}
        # Vivo exports may leave both name.mp4 and name(1).mp4. Attach only
        # byte-identical copies to the exact still/video pair; different clips stay visible.
        # Inspect siblings for explicitly selected stills as we already do for their primary video.
        try:
            candidates = sorted(os.path.join(d, name) for name in os.listdir(d)
                                if os.path.splitext(name)[1].lower() in (".mp4", ".mov", ".m4v"))
        except OSError:
            candidates = fs
        for candidate in candidates:
            if candidate in paired_video_paths:
                continue
            candidate_stem = os.path.splitext(candidate)[0]
            owner = candidate_stem if candidate_stem in image_stems else re.sub(r"\s*\(\d+\)$", "", candidate_stem)
            primary = videos.get(owner) if owner in image_stems else None
            if primary and candidate != primary and identical_media(primary, candidate, hashes):
                companions.setdefault(owner, []).append(candidate)
                paired_video_paths.add(candidate)
        for f in fs:
            stem, ext = os.path.splitext(f)
            if ext.lower() in VIDEO_EXTS:
                if f in paired_video_paths:
                    continue
                cap = tool_dates.get(os.path.abspath(f))
                jobs.append({"path": f, "name": os.path.basename(f), "kind": "video",
                             "reason": "独立视频", "date": cap[0] if cap else "", "make": ""})
                continue
            if ext.lower() not in IMAGE_EXTS:
                continue
            name = os.path.basename(f)

            if ext.lower() not in JPEG_EXTS:
                cap = tool_dates.get(os.path.abspath(f))
                jobs.append({"path": f, "name": name, "kind": "none" if cap else "other",
                             "reason": "没有找到动态视频" if cap else "缺少可识别的拍摄信息",
                             "date": cap[0] if cap else "", "make": tool_metadata.get(os.path.abspath(f), {}).get("Make", ""),
                             "model": tool_metadata.get(os.path.abspath(f), {}).get("Model", "")})
                continue

            if fast:
                # 扫描阶段只读文件头：足够看到 XMP 里的 MotionPhoto 标记和 EXIF Make，
                # 不必把整张 10MB 的图读进来，几千张的文件夹也能很快扫完。
                try:
                    with open(f, "rb") as fh:
                        head = fh.read(512 * 1024)
                except OSError as e:
                    jobs.append({"path": f, "name": name, "kind": "other", "reason": str(e), "make": ""})
                    continue
                make = jpeg_make(head) or tool_metadata.get(os.path.abspath(f), {}).get("Make", "")
                model = jpeg_model(head) or tool_metadata.get(os.path.abspath(f), {}).get("Model", "")
                gps = read_gps(head)
                live_type = detect_live_type(make)
                hdr_value = detect_hdr(head)
                cap = read_capture_date(head)
                cap = cap or tool_dates.get(os.path.abspath(f))
                date_value = cap[0] if cap else ""
                marked = any(m in head for m in (
                    b"GCamera:MotionPhoto", b"OpCamera:VideoLength",
                    b"VMotionPhotoVersion", b"MotionPhoto"))
                if marked:
                    jobs.append({"path": f, "name": name, "kind": "embedded",
                                 "vstart": 0, "vlen": 0, "video_path": videos.get(stem),
                                 "make": make, "model": model,
                                 "gps_lat": gps[0] if gps else None,
                                 "gps_lon": gps[1] if gps else None,
                                 "live_type": live_type, "hdr": hdr_value,
                                 "date": date_value, "size": os.path.getsize(f)})
                elif stem in videos:
                    jobs.append({"path": f, "name": name, "kind": "paired",
                                 "video_path": videos[stem], "make": make,
                                 "model": model,
                                 "gps_lat": gps[0] if gps else None,
                                 "gps_lon": gps[1] if gps else None,
                                 "live_type": live_type, "hdr": hdr_value,
                                 "date": date_value, "size": os.path.getsize(f)})
                else:
                    has_metadata = bool(date_value or make or model or gps)
                    jobs.append({"path": f, "name": name, "kind": "none" if has_metadata else "other",
                                 "reason": "没有找到动态视频" if has_metadata else "缺少可识别的照片信息",
                                 "make": make, "model": model,
                                 "gps_lat": gps[0] if gps else None,
                                 "gps_lon": gps[1] if gps else None,
                                 "live_type": live_type, "date": date_value})
                continue

            try:
                with open(f, "rb") as fh:
                    data = fh.read()
            except OSError as e:
                jobs.append({"path": f, "name": name, "kind": "other", "reason": str(e), "make": ""})
                continue
            vstart = find_appended_video(data)
            cap = read_capture_date(data)
            cap = cap or tool_dates.get(os.path.abspath(f))
            date_value = cap[0] if cap else ""
            make = jpeg_make(data)
            model = jpeg_model(data)
            gps = read_gps(data)
            live_type = detect_live_type(make)
            hdr_value = detect_hdr(data)
            if vstart is not None:
                vlen = motion_video_length(data, vstart)
                jobs.append({"path": f, "name": name, "kind": "embedded",
                             "vstart": vstart, "vlen": vlen, "video_path": None,
                             "make": make, "model": model,
                             "gps_lat": gps[0] if gps else None,
                             "gps_lon": gps[1] if gps else None,
                             "live_type": live_type, "hdr": hdr_value,
                             "date": date_value, "size": os.path.getsize(f)})
            elif stem in videos:
                jobs.append({"path": f, "name": name, "kind": "paired",
                             "video_path": videos[stem], "make": make,
                             "model": model,
                             "gps_lat": gps[0] if gps else None,
                             "gps_lon": gps[1] if gps else None,
                             "live_type": live_type, "hdr": hdr_value,
                             "date": date_value, "size": os.path.getsize(f)})
            else:
                has_metadata = bool(date_value or make or model or gps)
                jobs.append({"path": f, "name": name, "kind": "none" if has_metadata else "other",
                             "reason": "没有找到动态视频" if has_metadata else "缺少可识别的照片信息",
                             "make": make, "model": model,
                             "gps_lat": gps[0] if gps else None,
                             "gps_lon": gps[1] if gps else None,
                             "live_type": live_type, "date": date_value})
    for job in jobs:
        # Keep all physical files available to archive/delete operations, while showing one item.
        job["companion_videos"] = [os.path.basename(path) for path in companions.get(os.path.splitext(job["path"])[0], [])] if job["kind"] in ("embedded", "paired") else []
        if not job.get("date"):
            capture = capture_date_from_filename(job["path"])
            if capture:
                job["date"] = capture[0]
                job["date_source"] = "filename"
        if not job.get("date") and job["kind"] not in ("embedded", "paired"):
            job["reason"] = job.get("reason", "") + "；无可靠拍摄时间，保留原日期"
    jobs.sort(key=lambda j: os.path.basename(j["path"]).lower())
    return jobs


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def _video_info(path):
    if not (os.path.isfile(FFPROBE) or shutil.which(FFPROBE)):
        return None
    p = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-show_entries", "stream=codec_name,width,height",
             "-of", "json", path], check=False)
    try:
        obj = json.loads(p.stdout.decode("utf-8", "replace"))
    except Exception:
        return None
    streams = obj.get("streams") or []
    video = next((s for s in streams if s.get("width")), None)
    if not video:
        return None
    try:
        duration = float((obj.get("format") or {}).get("duration") or 0)
    except Exception:
        duration = 0
    return {"codec": video.get("codec_name", ""),
            "width": video.get("width"),
            "height": video.get("height"),
            "duration": round(duration, 2)}


def info_json(path):
    path = os.path.abspath(path)
    with open(path, "rb") as fh:
        d = fh.read() if path.lower().endswith(JPEG_EXTS) else fh.read(1024 * 1024)
    info = {
        "path": path,
        "name": os.path.basename(path),
        "size": os.path.getsize(path),
        "format": os.path.splitext(path)[1][1:].upper(),
        "kind": "none",
    }

    tags = {}
    if _exiftool_available():
        p = run([EXIFTOOL, "-json", "-api", "QuickTimeUTC=1",
                 "-DateTimeOriginal", "-CreationDate", "-CreateDate", "-DateCreated", "-MediaCreateDate",
                 "-OffsetTimeOriginal", "-OffsetTime",
                 "-Make", "-Model", "-LensModel",
                 "-FocalLength", "-FocalLengthIn35mmFormat",
                 "-FNumber", "-ExposureTime", "-ISO", "-ExposureCompensation",
                 "-ImageWidth", "-ImageHeight",
                 "-GPSLatitude", "-GPSLongitude", path], check=False)
        try:
            arr = json.loads(p.stdout.decode("utf-8", "replace"))
            if arr:
                tags = arr[0]
        except Exception:
            tags = {}

    capture = _capture_date_from_tool(tags) or capture_date_from_filename(path)
    info["date"] = capture[0] if capture else None
    info["date_offset"] = tags.get("OffsetTimeOriginal") or tags.get("OffsetTime") or ""
    info["make"] = tags.get("Make") or ""
    info["model"] = tags.get("Model") or ""
    info["live_type"] = detect_live_type(info["make"])
    info["hdr"] = detect_hdr(d)
    info["lens"] = tags.get("LensModel") or ""
    info["focal"] = tags.get("FocalLength") or ""
    info["focal_35"] = tags.get("FocalLengthIn35mmFormat") or ""
    info["aperture"] = str(tags.get("FNumber") or "")
    info["shutter"] = tags.get("ExposureTime") or ""
    info["iso"] = str(tags.get("ISO") or "")
    info["exposure_comp"] = "" if tags.get("ExposureCompensation") is None else str(tags.get("ExposureCompensation"))
    info["width"] = tags.get("ImageWidth") or 0
    info["height"] = tags.get("ImageHeight") or 0

    if _exiftool_available():
        p = run([EXIFTOOL, "-json", "-n", "-GPSLatitude", "-GPSLongitude", path], check=False)
        try:
            arr = json.loads(p.stdout.decode("utf-8", "replace"))
            if arr:
                info["gps_lat"] = arr[0].get("GPSLatitude")
                info["gps_lon"] = arr[0].get("GPSLongitude")
        except Exception:
            pass

    vstart = find_appended_video(d) if path.lower().endswith(JPEG_EXTS) else None
    video_path = None
    temp_path = None
    if vstart is not None:
        vlen = motion_video_length(d, vstart)
        tmp = tempfile.NamedTemporaryFile(suffix=".mov", delete=False)
        tmp.write(d[vstart:vstart + vlen])
        tmp.close()
        temp_path = tmp.name
        video_path = temp_path
        info["kind"] = "embedded"
    else:
        stem, _ = os.path.splitext(path)
        for ext in (".mov", ".MOV", ".mp4", ".MP4", ".m4v", ".M4V"):
            if os.path.exists(stem + ext):
                video_path = stem + ext
                info["kind"] = "paired"
                break

    if os.path.splitext(path)[1].lower() in VIDEO_EXTS:
        video_path = path
        info["kind"] = "video"
    if video_path:
        vinfo = _video_info(video_path)
        if vinfo:
            info["video"] = vinfo
        uuid_value = read_video_uuid(video_path)
        if uuid_value:
            info["uuid"] = uuid_value
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass
    return info


def write_capture_time(path, capture):
    """Write Apple-readable capture dates without changing encoded media or pairing IDs."""
    if not _exiftool_available():
        raise RuntimeError("时间修复需要 exiftool")
    date, ts = capture
    offset = date[19:]
    args = [EXIFTOOL, "-overwrite_original", "-api", "QuickTimeUTC=1"]
    if os.path.splitext(path)[1].lower() in VIDEO_EXTS:
        args += ["-Keys:CreationDate=" + date]
        args += ["-QuickTime:" + tag + "=" + date for tag in
                 ("CreateDate", "ModifyDate", "TrackCreateDate", "TrackModifyDate", "MediaCreateDate", "MediaModifyDate")]
    else:
        args += ["-EXIF:" + tag + "=" + date[:19] for tag in
                 ("DateTimeOriginal", "CreateDate", "ModifyDate")]
        args += ["-EXIF:" + tag + "=" + offset for tag in
                 ("OffsetTime", "OffsetTimeOriginal", "OffsetTimeDigitized")]
        # Fractional seconds from old metadata must not override the requested second.
        args += ["-EXIF:SubSecTime=", "-EXIF:SubSecTimeOriginal=", "-EXIF:SubSecTimeDigitized="]
        args += ["-XMP:DateTimeOriginal=" + date, "-XMP:CreateDate=" + date,
                 "-XMP:ModifyDate=" + date]
    args += ["-FileCreateDate=" + date, "-FileModifyDate=" + date, path]
    result = run(args)
    if b"1 image files updated" not in result.stdout:
        raise RuntimeError("未能写入拍摄时间：" + result.stdout.decode("utf-8", "replace"))
    os.utime(path, (ts, ts))
    tags = json.loads(run([EXIFTOOL, "-json", "-api", "QuickTimeUTC=1",
                          "-DateTimeOriginal", "-CreationDate", "-OffsetTimeOriginal", path]).stdout)[0]
    actual = _capture_date_from_tool(tags)
    if not actual or abs(actual[1] - ts) > 1:
        raise RuntimeError("写入后的拍摄时间校验失败")


def time_job_sources(job):
    sources = [job["path"]]
    if job.get("video_path"):
        sources.append(job["video_path"])
    sources += [os.path.join(os.path.dirname(job["path"]), name)
                for name in job.get("companion_videos", [])]
    return list(dict.fromkeys(sources))


def publish_time_asset(staged, folder, stem):
    """Keep pairs flat and rename together on collision; roll back partial publication."""
    os.makedirs(folder, exist_ok=True)
    number = 1
    while True:
        suffix = "" if number == 1 else "_" + str(number)
        names = []
        for path in staged:
            name = os.path.basename(path)
            names.append(stem + suffix + name[len(stem):] if name.startswith(stem)
                         else os.path.splitext(name)[0] + suffix + os.path.splitext(name)[1])
        targets = [os.path.join(folder, name) for name in names]
        if any(os.path.lexists(path) for path in targets):
            number += 1
            continue
        published = []
        try:
            for source, target in zip(staged, targets):
                # Exclusive creation also works on exFAT source disks and refuses overwrite.
                with open(source, "rb") as incoming, open(target, "xb") as outgoing:
                    published.append(target)
                    shutil.copyfileobj(incoming, outgoing)
                shutil.copystat(source, target)
            return targets
        except Exception:
            for path in reversed(published):
                os.unlink(path)
            raise


def repair_time_jobs(jobs, output, manual=None, source_output=False, still_only=False, use_modified_date=False):
    """Publish repaired copies and failed originals into their batch categories."""
    extensions = IMAGE_EXTS if still_only else IMAGE_EXTS + VIDEO_EXTS
    jobs = [job for job in jobs if os.path.splitext(job["path"])[1].lower() in extensions]
    folders = {}
    job_folders = {}
    batch_name = "已批量处理_" + datetime.datetime.now().strftime("%Y.%m.%d-%I.%M.%S.%p").lower()
    for job in jobs:
        parent = os.path.dirname(os.path.abspath(job["path"])) if source_output else os.path.abspath(output)
        ancestor = parent
        while source_output and ancestor != os.path.dirname(ancestor):
            if os.path.basename(ancestor).startswith("已批量处理_"):
                job_folders[job["path"]] = ancestor
                break
            ancestor = os.path.dirname(ancestor)
        if job["path"] in job_folders:
            continue
        if parent in folders:
            continue
        os.makedirs(parent, exist_ok=True)
        base = os.path.join(parent, batch_name)
        folder = base
        number = 1
        while True:
            try:
                os.mkdir(folder)
                break
            except FileExistsError:
                number += 1
                folder = base + "_" + str(number)
        folders[parent] = folder
    all_folders = list(dict.fromkeys([*job_folders.values(), *folders.values()]))
    emit({"type": "time_begin", "total": len(jobs), "folders": all_folders, "batch": len(jobs) > 1})
    ok = fail = 0
    for job in jobs:
        path = job["path"]
        parent = os.path.dirname(os.path.abspath(path)) if source_output else os.path.abspath(output)
        folder = job_folders.get(path) or folders[parent]
        sources = [job["path"]] if still_only else time_job_sources(job)
        stem = os.path.splitext(os.path.basename(path))[0]
        emit({"type": "time_start", "path": path})
        try:
            capture = manual or _capture_date_from_tool({"DateTimeOriginal": job.get("date")})
            if use_modified_date:
                modified = datetime.datetime.fromtimestamp(os.stat(path).st_mtime).astimezone()
                capture = _capture_date_from_tool({"DateTimeOriginal": modified.strftime("%Y:%m:%d %H:%M:%S%z")})
            if not capture:
                raise RuntimeError("没有可靠拍摄时间，请使用「手动指定」")
            os.makedirs(folder, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".repair-", dir=folder) as stage:
                staged = []
                for source in sources:
                    target = os.path.join(stage, os.path.basename(source))
                    if target.lower().endswith(".png"):
                        with open(source, "rb") as original:
                            if original.read(3) == b"\xff\xd8\xff":
                                target = os.path.splitext(target)[0] + ".jpg"
                                emit({"type": "time_note", "message": os.path.basename(source) + " 的内容是 JPEG，副本使用 .jpg 扩展名。"})
                    shutil.copy2(source, target)
                    write_capture_time(target, capture)
                    staged.append(target)
                destination = os.path.join(folder, "为图片写入时间")
                if not still_only and job["kind"] in ("paired", "embedded"):
                    destination = os.path.join(destination, "实况")
                targets = publish_time_asset(staged, destination, stem)
            ok += 1
            emit({"type": "time_ok", "path": path, "date": capture[0], "folder": folder, "files": targets,
                  "partial": still_only and job["kind"] in ("paired", "embedded")})
        except Exception as error:
            fail += 1
            failure_folder = None
            backup_error = None
            if sources:
                try:
                    failed = os.path.join(folder, "失败", "写入时间")
                    with tempfile.TemporaryDirectory(prefix=".failed-", dir=folder) as stage:
                        staged = []
                        for source in sources:
                            if not os.path.isfile(source):
                                continue
                            target = os.path.join(stage, os.path.basename(source))
                            shutil.copy2(source, target)
                            staged.append(target)
                        if staged:
                            publish_time_asset(staged, failed, stem)
                            failure_folder = failed
                except Exception as backup:
                    backup_error = "失败原片副本保存失败，原文件保留在原位：" + str(backup)
            emit({"type": "time_fail", "path": path, "error": str(error),
                  "folder": failure_folder, "backup_error": backup_error})
    emit({"type": "time_done", "ok": ok, "fail": fail,
          "folders": all_folders})
    return 1 if fail else 0


def main():
    ap = argparse.ArgumentParser(description="Android 动态照片 -> Apple 实况照片（无损）")
    ap.add_argument("inputs", nargs="+", help="文件或文件夹")
    ap.add_argument("-o", "--output", default="output", help="输出目录")
    ap.add_argument("--scan", action="store_true", help="只扫描，输出 JSON 行")
    ap.add_argument("--info", action="store_true", help="输出单个文件的元数据 JSON")
    ap.add_argument("--json", action="store_true", help="转换时输出 JSON 行")
    ap.add_argument("--repair-time", action="store_true", help="仅修复拍摄时间，输出副本")
    ap.add_argument("--capture-time", help="手动时间，含时区，如 2026:07:23 10:05:00+08:00")
    ap.add_argument("--time-source", action="store_true", help="时间修复保存到每个源文件夹")
    ap.add_argument("--time-still-only", action="store_true", help="只修复静态图片，不处理配对视频")
    ap.add_argument("--time-use-modified-date", action="store_true", help="使用文件的最后修改时间")
    ap.add_argument("--preview-time", action="store_true", help="预览将使用的拍摄时间")
    args = ap.parse_args()

    if args.info:
        emit(info_json(args.inputs[0]))
        return 0

    jobs = collect_jobs(args.inputs, fast=args.scan or args.preview_time)
    if args.preview_time:
        for job in jobs:
            emit({"type": "time_preview", "path": job["path"], "members": time_job_sources(job),
                  "date": job.get("date", ""), "date_source": job.get("date_source", "metadata")})
        return 0

    if args.repair_time:
        manual = _capture_date_from_tool({"DateTimeOriginal": args.capture_time}) if args.capture_time else None
        if args.capture_time and not manual:
            ap.error("指定时间无效")
        return repair_time_jobs(jobs, args.output, manual, args.time_source, args.time_still_only, args.time_use_modified_date)

    if args.scan:
        convertible = 0
        total = 0
        for j in jobs:
            total += 1
            ok = j["kind"] in ("embedded", "paired")
            if ok:
                convertible += 1
            emit({"type": "scan", "path": j["path"], "name": j["name"],
                  "kind": j["kind"], "make": j.get("make", ""),
                  "video": os.path.basename(j["video_path"]) if j.get("video_path") else None,
                  "companion_videos": j.get("companion_videos", []),
                  "convertible": ok, "reason": j.get("reason", ""),
                  "date": j.get("date", ""), "date_source": j.get("date_source", "metadata"), "model": j.get("model", ""),
                  "live_type": j.get("live_type", ""), "hdr": j.get("hdr", "SDR"),
                  "gps_lat": j.get("gps_lat"), "gps_lon": j.get("gps_lon")})
        emit({"type": "scan_done", "count": convertible,
              "total": total, "unsupported": total - convertible})
        return 0

    os.makedirs(args.output, exist_ok=True)
    convertible = [j for j in jobs if j["kind"] in ("embedded", "paired")]
    if args.json:
        emit({"type": "begin", "total": len(convertible)})

    ok = fail = skip = 0
    for j in jobs:
        if j["kind"] not in ("embedded", "paired"):
            skip += 1
            if args.json:
                emit({"type": "skip", "path": j["path"], "name": j["name"],
                      "reason": j.get("reason", "")})
            else:
                print("SKIP %s  (%s)" % (j["path"], j.get("reason", "")))
            continue

        if args.json:
            emit({"type": "start", "path": j["path"], "name": j["name"]})
        try:
            base = os.path.splitext(j["name"])[0]
            capture = _capture_date_from_tool({"DateTimeOriginal": j.get("date")})
            if j["kind"] == "embedded":
                with open(j["path"], "rb") as fh:
                    data = fh.read()
                video = data[j["vstart"]:j["vstart"] + j["vlen"]]
                value = convert_one(j["path"], None, args.output, embedded_video=video,
                                    still_bytes=data[:j["vstart"]], base=base, capture=capture)
            else:
                value = convert_one(j["path"], j["video_path"], args.output, base=base, capture=capture)
            ok += 1
            if args.json:
                emit({"type": "ok", "path": j["path"], "name": j["name"],
                      "uuid": value, "kind": j["kind"],
                      "out_jpg": os.path.join(args.output, base + ".jpg"),
                      "out_mov": os.path.join(args.output, base + ".mov")})
            else:
                label = "单文件内嵌视频" if j["kind"] == "embedded" else "配对视频"
                print("OK   %-42s  %s  %s" % (j["name"], label, value))
        except Exception as e:
            fail += 1
            if args.json:
                emit({"type": "fail", "path": j["path"], "name": j["name"],
                      "error": str(e), "log": traceback.format_exc()})
            else:
                print("FAIL %s  (%s)" % (j["name"], e))

    if args.json:
        emit({"type": "done", "ok": ok, "fail": fail, "skip": skip, "out": args.output})
    else:
        print("\n完成 %d 个；失败 %d 个；跳过 %d 个。" % (ok, fail, skip))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
