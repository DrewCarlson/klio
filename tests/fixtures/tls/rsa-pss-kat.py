#!/usr/bin/env python3
"""The RSA fixtures' computed parts, independent of klio's code:

- rsa-pss-kat-sha256.hex, rsa2049-pss-kat-sha256.hex and
  rsa2050-pss-kat-sha256.hex: an RSASSA-PSS signature (SHA-256,
  MGF1-SHA-256, 32-byte salt 00 01 .. 1f) over "klio RSA-PSS known answer"
  by server-rsa-key.pem, rsa2049-key.pem and rsa2050-key.pem, computed with
  Python integers from RFC 8017 §9.1.1 and §8.1.1, then verified by OpenSSL.
- rsa-even-e-key.pem: server-rsa-key.pem's PKCS#1 form with the public
  exponent replaced by 65536, which a key must not have.
- rsa-wrong-d-key.pem: server-rsa-key.pem's PKCS#1 form with a private
  exponent that is not the key's (d + 2), so n and e still match the
  certificate.

Run by rsa-fixtures.sh.
"""
import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OPENSSL = os.environ.get("OPENSSL", "openssl")


def key_numbers(path):
    text = subprocess.run([OPENSSL, "pkey", "-in", path, "-noout", "-text"],
                          capture_output=True, text=True, check=True).stdout
    fields = {}
    name = None
    for line in text.splitlines():
        m = re.match(r"^(\w+):\s*(\S*)", line)
        if m:
            name = m.group(1)
            rest = m.group(2)
            if name == "publicExponent":
                fields[name] = int(rest)
                name = None
            else:
                fields[name] = ""
            continue
        if name and line.startswith("    "):
            fields[name] += line.strip().replace(":", "")
    out = {}
    for k, v in fields.items():
        out[k] = v if isinstance(v, int) else int(v, 16)
    return out


def mgf1(seed, length):
    out = b""
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(seed + counter.to_bytes(4, "big")).digest()
        counter += 1
    return out[:length]


def emsa_pss_encode(msg, salt, em_bits):
    h_len = 32
    em_len = (em_bits + 7) // 8
    m_hash = hashlib.sha256(msg).digest()
    h = hashlib.sha256(b"\0" * 8 + m_hash + salt).digest()
    ps = b"\0" * (em_len - len(salt) - h_len - 2)
    db = ps + b"\x01" + salt
    masked = bytes(a ^ b for a, b in zip(db, mgf1(h, em_len - h_len - 1)))
    zero_bits = 8 * em_len - em_bits
    masked = bytes([masked[0] & (0xFF >> zero_bits)]) + masked[1:]
    return masked + h + b"\xbc"


def der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def der_int(v):
    b = v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big")
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\x02" + der_len(len(b)) + b


def pem(label, der):
    body = base64.encodebytes(der).decode().replace("\n", "")
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (label, "\n".join(lines), label)


def kat(key_name, out_name):
    key_path = os.path.join(HERE, key_name)
    k = key_numbers(key_path)
    n, e, d = k["modulus"], k["publicExponent"], k["privateExponent"]
    mod_bits = n.bit_length()
    mod_len = (mod_bits + 7) // 8
    msg = b"klio RSA-PSS known answer"
    salt = bytes(range(32))
    em = emsa_pss_encode(msg, salt, mod_bits - 1)
    s = pow(int.from_bytes(em, "big"), d, n)
    assert pow(s, e, n) == int.from_bytes(em, "big")
    sig = s.to_bytes(mod_len, "big")
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "msg"), "wb") as f:
            f.write(msg)
        with open(os.path.join(tmp, "sig"), "wb") as f:
            f.write(sig)
        subprocess.run([OPENSSL, "pkey", "-in", key_path, "-pubout", "-out", os.path.join(tmp, "pub.pem")], check=True)
        r = subprocess.run([OPENSSL, "dgst", "-sha256", "-sigopt", "rsa_padding_mode:pss", "-sigopt", "rsa_pss_saltlen:32",
                            "-verify", os.path.join(tmp, "pub.pem"), "-signature", os.path.join(tmp, "sig"),
                            os.path.join(tmp, "msg")], capture_output=True, text=True)
        if "Verified OK" not in r.stdout:
            sys.exit("OpenSSL did not verify the signature for " + key_name + ": " + r.stdout + r.stderr)
    with open(os.path.join(HERE, out_name), "w") as f:
        f.write(sig.hex())
    return k


def pkcs1_pem(k, e, d):
    fields = [0, k["modulus"], e, d, k["prime1"], k["prime2"], k["exponent1"], k["exponent2"], k["coefficient"]]
    body = b"".join(der_int(v) for v in fields)
    return pem("RSA PRIVATE KEY", b"\x30" + der_len(len(body)) + body)


def main():
    k = kat("server-rsa-key.pem", "rsa-pss-kat-sha256.hex")
    kat("rsa2049-key.pem", "rsa2049-pss-kat-sha256.hex")
    kat("rsa2050-key.pem", "rsa2050-pss-kat-sha256.hex")
    with open(os.path.join(HERE, "rsa-even-e-key.pem"), "w") as f:
        f.write(pkcs1_pem(k, 65536, k["privateExponent"]))
    with open(os.path.join(HERE, "rsa-wrong-d-key.pem"), "w") as f:
        f.write(pkcs1_pem(k, k["publicExponent"], k["privateExponent"] + 2))
    print("known answers and crafted keys written; OpenSSL verified every signature")


if __name__ == "__main__":
    main()
