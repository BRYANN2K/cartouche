#!/usr/bin/env python3
"""Writes the hand-made seed corpora under fuzz/corpus/. Every seed is built here from the
formats' layouts, not copied from Steam, a game or an installer.

    python3 -I fuzz/make-seeds.py

The webpatch seeds come from the gate table instead: make fuzz-seeds.
"""
import os
import struct

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "corpus")
TOOL = "cartouche-proton"


def put(harness, name, data):
    d = os.path.join(ROOT, harness)
    os.makedirs(d, exist_ok=True)
    if isinstance(data, str):
        data = data.encode()
    with open(os.path.join(d, name), "wb") as f:
        f.write(data)


def pe_with_icon(magic=0x10B, images=1):
    """A PE with one .rsrc section: an RT_GROUP_ICON naming `images` RT_ICON entries."""
    peo, rsrc_raw, rsrc_va = 0x40, 0x200, 0x1000
    opt_size = (96 if magic == 0x10B else 112) + 16 * 8
    dos = bytearray(peo)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, peo)
    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x14C, 1, 0, 0, 0, opt_size, 0x102)
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, magic)
    count_at, dir_base = (92, 96) if magic == 0x10B else (108, 112)
    struct.pack_into("<I", opt, count_at, 16)

    # Resource tree: root -> type -> id -> language -> data entry
    tree = bytearray()

    def directory(entries):
        at = len(tree)
        tree.extend(struct.pack("<IIHHHH", 0, 0, 0, 0, 0, len(entries)))
        for name, off in entries:
            tree.extend(struct.pack("<II", name, off))
        return at

    icon = bytes(range(40))
    group = struct.pack("<HHH", 0, 1, images)
    for i in range(images):
        group += struct.pack("<BBBBHHIH", 16, 16, 0, 0, 1, 32, len(icon), i + 1)

    # Layout: directories first, data entries, then the payloads
    root = directory([(3, 0), (14, 0)])
    icon_ids = directory([(i + 1, 0) for i in range(images)])
    group_ids = directory([(1, 0)])
    icon_langs = [directory([(0x409, 0)]) for _ in range(images)]
    group_lang = directory([(0x409, 0)])
    icon_data = [len(tree) + 16 * i for i in range(images)]
    tree.extend(bytes(16 * images))
    group_data = len(tree)
    tree.extend(bytes(16))
    payload = len(tree)
    tree.extend(icon)
    group_at = len(tree)
    tree.extend(group)

    def link(dir_at, index, target, leaf=False):
        struct.pack_into("<I", tree, dir_at + 16 + 8 * index + 4,
                         target if leaf else 0x80000000 | target)

    link(root, 0, icon_ids)
    link(root, 1, group_ids)
    for i in range(images):
        link(icon_ids, i, icon_langs[i])
        link(icon_langs[i], 0, icon_data[i], leaf=True)
        struct.pack_into("<II", tree, icon_data[i], rsrc_va + payload, len(icon))
    link(group_ids, 0, group_lang)
    link(group_lang, 0, group_data, leaf=True)
    struct.pack_into("<II", tree, group_data, rsrc_va + group_at, len(group))

    struct.pack_into("<II", opt, dir_base + 16, rsrc_va, len(tree))
    section = struct.pack("<8sIIIIIIHHI", b".rsrc", len(tree), rsrc_va, len(tree), rsrc_raw,
                          0, 0, 0, 0, 0x40000040)
    head = bytes(dos) + coff + bytes(opt) + section
    return head + bytes(rsrc_raw - len(head)) + bytes(tree)


put("peicon", "pe32-one-icon.exe", pe_with_icon())
put("peicon", "pe32plus-two-icons.exe", pe_with_icon(0x20B, images=2))
put("peicon", "mz-only.exe", b"MZ" + bytes(0x3E))

put("aob", "plain", "FD7BBFA9FD030091 ????????" + "\xfd\x7b\xbf\xa9\xfd\x03\x00\x91" * 3)
put("aob", "wildcards", "?? 00 ?? 01" + "\x00\x00\x00\x01" * 4)

put("sigdb", "profile.json", """{
  "schema_version": 3, "profile_version": 7, "steam_build": "1790000000",
  "steam_build_date": "2026-10-01",
  "signatures": [
    {"name": "A::String", "anchor": {"kind": "string", "value": "hello", "nth_xref": 1}},
    {"name": "A::After", "anchor": {"kind": "insn_after_string", "value": "x", "n": 2}},
    {"name": "A::Pair", "anchor": {"kind": "insn_pair_in_fn", "value": "y",
      "pair": {"first": "0xd503201f", "first_mask": "0xffffffff",
               "second": "0x91000000", "second_mask": "0xff000000", "land": "second"}}},
    {"name": "A::Call", "anchor": {"kind": "call_target", "value": "z", "call_path": [1, 2],
      "caller_hops": 1, "caller_tail": true}},
    {"name": "A::Slot", "anchor": {"kind": "vtable_slot", "va": "0x1234"}},
    {"name": "A::Calls", "anchor": {"kind": "calls", "calls": ["malloc", "free"], "exact": true}},
    {"name": "A::Aob", "aob_hex": "FD 7B ?? A9", "match_offset": 4, "anchor": {"kind": "aob"}},
    {"name": "A::Old", "deprecated": true, "module": "steamui.dylib"}
  ]
}
""")

# loginusers.vdf, first byte odd for the harness
put("libexport", "loginusers.vdf", "\x01" + """"users"
{
\t"76561197960287930"
\t{
\t\t"AccountName"\t\t"someone"
\t\t"PersonaName"\t\t"Some \\"One\\""
\t\t"MostRecent"\t\t"0"
\t\t"Timestamp"\t\t"1790000000"
\t}
\t"76561197960287931"
\t{
\t\t"AccountName"\t\t"other"
\t\t"MostRecent"\t\t"1"
\t\t"Timestamp"\t\t"1700000000"
\t}
}
""")
put("libexport", "export.json", "\x02" + """{"version":1,"generated":1790000000,
"steamid":"76561197960287930","apps":[
{"appid":10,"name":"Game","installed":true,"last_played":1790000000,"playtime":42,"hidden":false},
{"appid":20,"name":"Other","installed":false}],
"collections":[{"id":"uc-1","name":"Favs","apps":[10,20]}]}""")

put("compat", "tools", "\x00" + f"{TOOL}\twine-11.0_1\trosetta\tCartouche (Wine 11)\n"
    f"{TOOL}-fex\twine-11.0_1\tfex\tCartouche FEX\n")
put("compat", "backends", "\x01" + f"{TOOL}-dxmt\twine-11.0_1\trosetta\tdxmt\tCartouche DXMT\n"
    f"{TOOL}-d3dm\twine-11.0_1\tfex\td3dmetal\tCartouche D3DMetal\n")
put("compat", "requests", "\x02" + f"10\t{TOOL}\n20\t\n0\t{TOOL}-fex\n")

put("nativeplatform", "lists", "mac=10,20,30\nwindows=40,50\n")
put("nativeplatform", "empty", "mac=\nwindows=\n")

put("spawn", "steam_osx", "/Applications/Steam.app/Contents/MacOS/steam_osx\n"
    "HOME=/Users/u\nDYLD_INSERT_LIBRARIES=/x/cartouche.dylib\nSDL_JOYSTICK_BLACKLIST_DEVICES=0x1\n")
put("spawn", "other", "/bin/sh\nPATH=/usr/bin\nDYLD_INSERT_LIBRARIES=/x/cartouche.dylib\n")

put("launch", "no-shell", "DXVK_HUD=1 %command% -windowed 'it''s'")
put("launch", "shell", b"/bin/zsh -l\0" + b"FOO=\"a b\" %command% C:\\Games\\x.exe")

put("framegen_env", "temporal", "\x00sharpness=0.5,jitter=1,exposure=-1,mv_jittered=1,"
    "reactive=0.2,fx=1,bounds=1")
put("framegen_env", "upscale", "\x01cmaa2+metalfx+rcas=0.3")
put("framegen_env", "overlay", "\x02std")
put("framegen_env", "corner", "\x03bl")
