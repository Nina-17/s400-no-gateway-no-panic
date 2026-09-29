#!/usr/bin/env python3
"""Extract one target's authenticated parcels from Apple tab-delimited output.

Only accepts a single LOGIN in the trace. No token is read and no frame bytes
are printed. Attribute mapping must come from discovery in this capture.
"""
import argparse
import json
import os
from datetime import datetime
from pathlib import Path


def extract(source, mac, device_id):
    channels = {}
    rows = []
    for line in source.read_text().splitlines():
        p = line.split("\t")
        if len(p) < 8 or p[2].upper() != mac.upper() or not p[1].startswith("ATT"):
            continue
        raw = bytes.fromhex(p[7])
        if len(raw) < 9 or int.from_bytes(raw[6:8], "little") != 4:
            raise ValueError("Expected complete ATT L2CAP packet")
        if int.from_bytes(raw[4:6], "little") != len(raw) - 8:
            raise ValueError("Fragmented L2CAP needs reassembly first")
        att = raw[8:]
        # Characteristic declaration response (7-byte records, 16-bit UUID).
        if att[0] == 0x09 and len(att) > 1 and att[1] == 7:
            if (len(att) - 2) % 7:
                raise ValueError("Truncated characteristic declaration")
            for i in range(2, len(att), 7):
                channels[int.from_bytes(att[i+3:i+5], "little")] = f"{int.from_bytes(att[i+5:i+7], 'little'):04X}"
        if att[0] in (0x52, 0x1B):
            rows.append((datetime.fromisoformat(p[0]), "send" if att[0] == 0x52 else "receive",
                         int.from_bytes(att[1:3], "little"), att[3:]))
    logins = [t for t, d, h, v in rows if d == "send" and channels.get(h) == "0010" and v == bytes.fromhex("24000000")]
    if len(logins) != 1:
        raise ValueError("Require exactly one captured LOGIN")
    start = logins[0]
    parcels, pending = [], {}
    for t, direction, handle, value in rows:
        channel = channels.get(handle)
        if t < start or channel not in ("0019", "001A", "001B"):
            continue
        key = direction, channel
        if len(value) == 4 and value[:3] == bytes([0, 0, 1]):
            continue  # transport ACK, not an application message
        if len(value) == 6 and value[:3] == bytes(3):
            if key in pending:
                raise ValueError("Overlapping parcel")
            count = int.from_bytes(value[4:6], "little")
            if not 1 <= count <= 228:
                raise ValueError("Oversized parcel")
            pending[key] = [count, 1, bytearray(), t]
            continue
        if key not in pending:
            raise ValueError(f"Data without parcel header on {channel}")
        state = pending[key]
        if not 3 <= len(value) <= 20 or int.from_bytes(value[:2], "little") != state[1]:
            raise ValueError("Missing or out-of-order fragment")
        state[2].extend(value[2:]); state[1] += 1
        if state[1] > state[0]:
            parcels.append(dict(channel=channel, direction=direction,
                                offset=(state[3] - start).total_seconds(), data=bytes(state[2]).hex()))
            del pending[key]
    if pending:
        raise ValueError("Incomplete final parcel")
    auth_send = [p for p in parcels if p['channel'] == '0019' and p['direction'] == 'send']
    auth_receive = [p for p in parcels if p['channel'] == '0019' and p['direction'] == 'receive']
    if [len(bytes.fromhex(p['data'])) for p in auth_send] != [16, 32] or [len(bytes.fromhex(p['data'])) for p in auth_receive] != [16, 32]:
        raise ValueError("Unexpected authentication exchange")
    return dict(deviceID=device_id, appRandom=auth_send[0]['data'], appHMAC=auth_send[1]['data'],
                deviceRandom=auth_receive[0]['data'], remoteHMAC=auth_receive[1]['data'],
                packets=[p for p in parcels if p['channel'] != '0019'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--mac', required=True)
    parser.add_argument('--device-id', required=True)
    args = parser.parse_args()
    result = extract(args.input, args.mac, args.device_id)
    os.umask(0o077)
    with args.output.open('x') as f:
        json.dump(result, f)
    print('Prepared', len(result['packets']), 'encrypted packets; no token needed on Mac')
