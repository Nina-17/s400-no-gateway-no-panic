#!/usr/bin/env python3
"""Public synthetic inputs only. Independent Python oracle, cryptography AESCCM.
Protocol parameters match xiaomi-s400-live crypto.py at 4f39dc48a7d22e1c9c15a4ecd0db684aa1ea9282.
No device credentials, BLE or network access. Requires cryptography.
"""
import hashlib
import hmac
import json
from pathlib import Path
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

token, app, device = bytes(range(12)), bytes(range(16)), bytes(range(16, 32))
derived = HKDF(algorithm=hashes.SHA256(), length=64, salt=app + device,
               info=b"mible-login-info").derive(token)
dev_key, app_key, dev_iv, app_iv = derived[:16], derived[16:32], derived[32:36], derived[36:40]
plaintexts = [b"\xa0700,1", bytes(range(16)), bytes(range(17)), bytes(range(255)),
              b"\xa0" + ",".join(map(str, [0, 0, 7, 700, 1, 2, 1790400000] + [0] * 23 + [5000, 6000])).encode()]
packets = []
app_packets = []
for counter, plain in enumerate(plaintexts, 1):
    prefix = counter.to_bytes(2, "little")
    nonce = dev_iv + bytes(4) + prefix + bytes(2)
    cipher = prefix + AESCCM(dev_key, tag_length=4).encrypt(nonce, plain, None)
    packets.append(dict(counter=counter, plaintext=plain.hex(), packet=cipher.hex()))
    app_nonce = app_iv + bytes(4) + prefix + bytes(2)
    app_cipher = prefix + AESCCM(app_key, tag_length=4).encrypt(app_nonce, plain, None)
    app_packets.append(dict(counter=counter, plaintext=plain.hex(), packet=app_cipher.hex()))
fixture = dict(token=token.hex(), appRandom=app.hex(), deviceRandom=device.hex(),
    deviceKey=dev_key.hex(), appKey=app_key.hex(), deviceIV=dev_iv.hex(), appIV=app_iv.hex(),
    remoteHMAC=hmac.new(dev_key, device + app, hashlib.sha256).hexdigest(),
    appHMAC=hmac.new(app_key, app + device, hashlib.sha256).hexdigest(), packets=packets, appPackets=app_packets)
path = Path(__file__).resolve().parents[1] / "Tests/ProbeCoreTests/Fixtures/protocol-vectors.json"
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(fixture, indent=2) + "\n")
print("Wrote synthetic protocol fixture; no real device credentials used.")
