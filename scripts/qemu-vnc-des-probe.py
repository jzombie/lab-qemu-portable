#!/usr/bin/env python3
"""Prove QEMU VNC password auth works end-to-end with real DES.

Spawns QEMU headless (TCG) with `-vnc 127.0.0.1:<disp>,password`, sets the
password over QMP/TCP, then performs a genuine RFB handshake as a VNC client:
reads the 16-byte challenge, DES-encrypts it with the password-derived key
(VNC bit-mirrored key schedule), sends the response, and requires the server
to reply auth-OK (uint32 0). Any crypto compiled out (no DES) fails here.

Pure stdlib (socket/struct/subprocess) + an embedded pure-Python DES, so it
runs on every CI leg (Linux/macOS/Windows) with no extra packages. The DES
implementation self-tests against the FIPS known-answer vector on startup:
a transcription error fails loudly instead of proving anything false.

Usage:
  vnc-des-probe.py --qemu <bin> (--bios <file> | --pflash <file>)
                   [--machine <name>] [--vnc-display N] [--qmp-port P]
  vnc-des-probe.py --self-test   # DES known-answer test only
"""
import argparse
import json
import socket
import struct
import subprocess
import sys
import time

# ---------------------------------------------------------------- DES tables
IP = (58, 50, 42, 34, 26, 18, 10, 2,
      60, 52, 44, 36, 28, 20, 12, 4,
      62, 54, 46, 38, 30, 22, 14, 6,
      64, 56, 48, 40, 32, 24, 16, 8,
      57, 49, 41, 33, 25, 17, 9, 1,
      59, 51, 43, 35, 27, 19, 11, 3,
      61, 53, 45, 37, 29, 21, 13, 5,
      63, 55, 47, 39, 31, 23, 15, 7)
FP = (40, 8, 48, 16, 56, 24, 64, 32,
      39, 7, 47, 15, 55, 23, 63, 31,
      38, 6, 46, 14, 54, 22, 62, 30,
      37, 5, 45, 13, 53, 21, 61, 29,
      36, 4, 44, 12, 52, 20, 60, 28,
      35, 3, 43, 11, 51, 19, 59, 27,
      34, 2, 42, 10, 50, 18, 58, 26,
      33, 1, 41, 9, 49, 17, 57, 25)
E = (32, 1, 2, 3, 4, 5,
     4, 5, 6, 7, 8, 9,
     8, 9, 10, 11, 12, 13,
     12, 13, 14, 15, 16, 17,
     16, 17, 18, 19, 20, 21,
     20, 21, 22, 23, 24, 25,
     24, 25, 26, 27, 28, 29,
     28, 29, 30, 31, 32, 1)
P = (16, 7, 20, 21,
     29, 12, 28, 17,
     1, 15, 23, 26,
     5, 18, 31, 10,
     2, 8, 24, 14,
     32, 27, 3, 9,
     19, 13, 30, 6,
     22, 11, 4, 25)
SBOX = (
    (14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
     0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
     4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
     15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13),
    (15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
     3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
     0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
     13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9),
    (10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
     13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
     13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
     1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12),
    (7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
     13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
     10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
     3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14),
    (2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
     14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
     4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
     11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3),
    (12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
     10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
     9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
     4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13),
    (4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
     13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
     1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
     6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12),
    (13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
     1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
     7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
     2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11),
)
PC1 = (57, 49, 41, 33, 25, 17, 9,
       1, 58, 50, 42, 34, 26, 18,
       10, 2, 59, 51, 43, 35, 27,
       19, 11, 3, 60, 52, 44, 36,
       63, 55, 47, 39, 31, 23, 15,
       7, 62, 54, 46, 38, 30, 22,
       14, 6, 61, 53, 45, 37, 29,
       21, 13, 5, 28, 20, 12, 4)
PC2 = (14, 17, 11, 24, 1, 5,
       3, 28, 15, 6, 21, 10,
       23, 19, 12, 4, 26, 8,
       16, 7, 27, 20, 13, 2,
       41, 52, 31, 37, 47, 55,
       30, 40, 51, 45, 33, 48,
       44, 49, 39, 56, 34, 53,
       46, 42, 50, 36, 29, 32)
ROTS = (1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1)


def _perm(block, table, nbits):
    out = 0
    width = len(table)
    for i, pos in enumerate(table):
        out |= ((block >> (nbits - pos)) & 1) << (width - 1 - i)
    return out


def _subkeys(key64):
    k = _perm(key64, PC1, 64)
    c, d = k >> 28, k & 0xFFFFFFF
    subs = []
    for r in ROTS:
        c = ((c << r) | (c >> (28 - r))) & 0xFFFFFFF
        d = ((d << r) | (d >> (28 - r))) & 0xFFFFFFF
        subs.append(_perm((c << 28) | d, PC2, 56))
    return subs


def _feistel(r32, sub):
    e = _perm(r32, E, 32) ^ sub
    s = 0
    for i in range(8):
        six = (e >> (42 - 6 * i)) & 0x3F
        row = ((six >> 5) << 1) | (six & 1)
        col = (six >> 1) & 0xF
        s = (s << 4) | SBOX[i][row * 16 + col]
    return _perm(s, P, 32)


def des_ecb_encrypt(block8, key8):
    blk = int.from_bytes(block8, "big")
    subs = _subkeys(int.from_bytes(key8, "big"))
    p = _perm(blk, IP, 64)
    left, right = p >> 32, p & 0xFFFFFFFF
    for i in range(16):
        left, right = right, left ^ _feistel(right, subs[i])
    return _perm((right << 32) | left, FP, 64).to_bytes(8, "big")


def _rev_byte(b):
    out = 0
    for _ in range(8):
        out = (out << 1) | (b & 1)
        b >>= 1
    return out


def vnc_encrypt_challenge(challenge16, password):
    """VNC auth: password-derived DES key, ECB over both challenge halves."""
    pw = password.encode("ascii")[:8].ljust(8, b"\0")
    key = bytes(_rev_byte(b) for b in pw)
    return (des_ecb_encrypt(challenge16[:8], key)
            + des_ecb_encrypt(challenge16[8:], key))


def des_self_test():
    # FIPS PUB 81 known-answer test (ECB).
    key = bytes.fromhex("133457799BBCDFF1")
    pt = bytes.fromhex("0123456789ABCDEF")
    want = bytes.fromhex("85E813540F0AB405")
    got = des_ecb_encrypt(pt, key)
    if got != want:
        raise SystemExit(
            "DES self-test FAILED: got %s want %s (tables mistranscribed?)"
            % (got.hex(), want.hex()))
    print("DES self-test OK (FIPS KAT %s -> %s)" % (pt.hex(), got.hex()))


# ---------------------------------------------------------------- RFB client
def _recvall(sock, n, what):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise SystemExit("FAIL: EOF reading %s (%d/%d bytes)" % (what, len(buf), n))
        buf += chunk
    return buf


def _qmp(sock, buf, cmd):
    # Line-buffered QMP request/response. The server may coalesce several
    # JSON objects per TCP packet (e.g. SHUTDOWN event + quit return) and may
    # interleave async events, so consume exactly one line per reply and skip
    # anything that isn't this command's response.
    sock.sendall((json.dumps(cmd) + "\n").encode())
    while True:
        while b"\n" not in buf[0]:
            chunk = sock.recv(4096)
            if not chunk:
                raise SystemExit("FAIL: EOF on QMP socket during %s" % cmd)
            buf[0] += chunk
        line, buf[0] = buf[0].split(b"\n", 1)
        if not line.strip():
            continue
        reply = json.loads(line.decode())
        if "event" in reply:
            print("QMP event: %s" % reply["event"], flush=True)
            continue
        if "error" in reply:
            raise SystemExit("FAIL: QMP %s -> error %s" % (cmd, reply["error"]))
        return reply


def prove(qemu, fw_args, machine, vnc_display, qmp_port, password):
    proc = None
    qmp = None
    try:
        cmd = [qemu, "-display", "none", "-accel", "tcg", "-m", "256",
               *fw_args, "-nic", "none", "-snapshot",
               "-vnc", "127.0.0.1:%d,password" % vnc_display,
               "-qmp", "tcp:127.0.0.1:%d,server,nowait" % qmp_port]
        if machine:
            cmd += ["-M", machine]
        print("+ %s" % " ".join(cmd), flush=True)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)

        deadline = time.time() + 30
        while True:
            try:
                qmp = socket.create_connection(("127.0.0.1", qmp_port), timeout=5)
                break
            except OSError:
                if proc.poll() is not None:
                    raise SystemExit("FAIL: QEMU exited early rc=%d\n%s"
                                     % (proc.returncode, proc.stdout.read()))
                if time.time() > deadline:
                    raise SystemExit("FAIL: QMP never came up")
                time.sleep(0.5)
        qmp.settimeout(10)
        qbuf = [b""]
        # QMP greeting is one JSON line (buffered: more may already coalesce).
        while b"\n" not in qbuf[0]:
            qbuf[0] += qmp.recv(4096)
        greet, qbuf[0] = qbuf[0].split(b"\n", 1)
        print("QMP greeting: %s" % greet.decode().strip(), flush=True)
        _qmp(qmp, qbuf, {"execute": "qmp_capabilities"})
        r = _qmp(qmp, qbuf, {"execute": "set_password",
                             "arguments": {"protocol": "vnc", "password": password}})
        print("set_password -> %s" % r, flush=True)

        vnc = socket.create_connection(("127.0.0.1", 5900 + vnc_display), timeout=10)
        try:
            srv_ver = _recvall(vnc, 12, "server version")
            print("server version: %r" % srv_ver, flush=True)
            vnc.sendall(srv_ver)  # mirror 3.8
            ntypes = _recvall(vnc, 1, "security-type count")[0]
            if ntypes == 0:
                reason_len = struct.unpack(">I", _recvall(vnc, 4, "reason len"))[0]
                reason = _recvall(vnc, reason_len, "reason").decode("utf-8", "replace")
                raise SystemExit("FAIL: server refused VNC auth: %s" % reason)
            types = list(_recvall(vnc, ntypes, "security types"))
            print("offered security types: %s" % types, flush=True)
            if 2 not in types:
                raise SystemExit("FAIL: VNC auth (type 2) not offered: %s" % types)
            vnc.sendall(bytes([2]))
            challenge = _recvall(vnc, 16, "VNC challenge")
            print("challenge: %s" % challenge.hex(), flush=True)
            vnc.sendall(vnc_encrypt_challenge(challenge, password))
            (result,) = struct.unpack(">I", _recvall(vnc, 4, "auth result"))
            if result != 0:
                raise SystemExit("FAIL: VNC auth rejected (result=%d) — DES mismatch?" % result)
            print("DES-PROOF-OK: server accepted DES-encrypted challenge response", flush=True)
        finally:
            vnc.close()

        try:
            _qmp(qmp, qbuf, {"execute": "quit"})
        except SystemExit as e:
            print("%s (proceeding to terminate)" % e, flush=True)
        finally:
            qmp.close()
            qmp = None
        # 'quit' is best-effort: some builds ignore it while a guest runs, so
        # never let shutdown hang the proof that already succeeded.
        try:
            rc = proc.wait(timeout=10)
            print("QEMU quit cleanly rc=%d" % rc, flush=True)
        except subprocess.TimeoutExpired:
            print("note: QMP quit ignored, terminating", flush=True)
            proc.kill()
            proc.wait()
    finally:
        if qmp is not None:
            qmp.close()
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()
    print("VNC-DES-PROOF-OK", flush=True)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--qemu")
    fw = ap.add_mutually_exclusive_group()
    fw.add_argument("--bios")
    fw.add_argument("--pflash")
    ap.add_argument("--machine", default=None)
    ap.add_argument("--vnc-display", type=int, default=99)
    ap.add_argument("--qmp-port", type=int, default=4447)
    ap.add_argument("--password", default="vncpw123")
    a = ap.parse_args(argv)
    des_self_test()
    if a.self_test:
        return 0
    if not a.qemu or (not a.bios and not a.pflash):
        ap.error("--qemu and --bios/--pflash are required (or --self-test)")
    fw_args = ["-bios", a.bios] if a.bios else \
        ["-drive", "if=pflash,format=raw,readonly=on,file=%s" % a.pflash]
    prove(a.qemu, fw_args, a.machine, a.vnc_display, a.qmp_port, a.password)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
