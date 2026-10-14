#!/usr/bin/env python3
"""Production QEMU with simulated BAR/FIFO and TAP, without touching hardware."""
import ctypes
import json
import mmap
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

QEMU, SHIM = map(lambda value: str(Path(value).resolve()), sys.argv[1:3])
TRANSPORT = sys.argv[3] if len(sys.argv) > 3 else "bar-fifo"
BRIDGE = TRANSPORT == "qdma-bridge"
QDMA = TRANSPORT in ("qdma-cmpt", "qdma-bridge")
ATOMIC = ctypes.CDLL(str(SHIM))
ATOMIC.scope_test_store32.argtypes = (ctypes.c_void_p, ctypes.c_uint32)
ATOMIC.scope_test_store16.argtypes = (ctypes.c_void_p, ctypes.c_uint16)
FPGA = "fffe:00:01.0"
MBX, ECAM, FIFO = 0x200000, 0x220000, 0x240000
GUEST, ALIAS = 0x80000000, 0x100000000


def put(mem, offset, value):
    ATOMIC.scope_test_store32(ctypes.addressof(ctypes.c_char.from_buffer(mem, offset)), value)


def get(mem, offset):
    return struct.unpack_from("<I", mem, offset)[0]


def wait(predicate, proc, message):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if predicate():
            return
        if proc.poll() is not None:
            raise AssertionError(f"QEMU exited: {message}")
        time.sleep(0.0001)
    raise AssertionError(f"timeout: {message}")


def run(mode):
    with tempfile.TemporaryDirectory(prefix="kmh-host-proxy-") as temporary:
        root = Path(temporary)
        (root / FPGA).mkdir()
        (root / FPGA / "resource").write_text(
            "0 0 0\n10000000 10ffffff 200\n800000000 bffffffff 200\n"
            "0 0 0\n0 0 0\n0 0 0\n")
        config = {"version": 1, "devices": [{"type": "host-net", "tap-name": "xsai0"}]}
        if mode == "bad-config":
            config["devices"][0]["real-host-bdf"] = "0000:01:00.0"
        (root / "backends.json").write_text(json.dumps(config))
        for name, size in (("user", 0x1000000), ("bypass", 0x400000000)):
            with (root / name).open("wb") as handle:
                handle.truncate(size)
        user_file = (root / "user").open("r+b")
        user = mmap.mmap(user_file.fileno(), 0)
        put(user, FIFO, 0x53434231 if BRIDGE else 0x53435131 if QDMA else 0x53465131)
        put(user, FIFO + 4, 1 if QDMA else 32)
        put(user, FIFO + 12, 1)
        put(user, FIFO + (28 if BRIDGE else 20), 0 if mode == "no-coherency" else 3 if BRIDGE else 1)
        if mode == "bad-abi":
            put(user, FIFO, 0)
        tap_peer, tap_backend = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        tap_peer.settimeout(5)
        env = dict(os.environ, LD_PRELOAD=SHIM, SCOPE_TEST_SYSFS=temporary,
                   SCOPE_TEST_TAP_FD=str(tap_backend.fileno()))
        cq_file = cq = None
        produced = 0
        if QDMA:
            cq_file = (root / "notify").open("w+b")
            cq_file.truncate(4096)
            cq = mmap.mmap(cq_file.fileno(), 4096)
            env["SCOPE_TEST_QDMA"] = str(root / "notify")
        if mode == "backpressure":
            env["SCOPE_TEST_TAP_EAGAIN"] = "1"
        device = (
            f"scope-fpga-vswitch,id=scope,bus=rp,backend-config={root / 'backends.json'},"
            f"fpga-host-bdf={FPGA},xdma-user-dev={root / 'user'},"
            f"xdma-bypass-dev={root / 'bypass'},control-transport={TRANSPORT},"
            f"mailbox-offset={MBX},ecam-shadow-offset={ECAM},fifo-offset={FIFO},"
            "guest-ddr-base=0x80000000,guest-ddr-size=0x80000000"
        )
        if QDMA:
            device += f",qdma-notify-dev={root / 'notify'}"
            if BRIDGE:
                device += ",qdma-ring-entries=8"
        if mode == "overlap":
            device = device.replace(f"fifo-offset={FIFO}", f"fifo-offset={MBX}")
        logfile = (root / "qemu.log").open("w+")
        proc = subprocess.Popen(
            [QEMU, "-L", str(Path(__file__).resolve().parents[2] / "tools/host/qemu/pc-bios"),
             "-machine", "q35", "-S", "-m", "128M", "-display", "none",
             "-monitor", "none", "-serial", "none", "-device", "pcie-root-port,id=rp",
             "-device", device], env=env, pass_fds=(tap_backend.fileno(),),
            stdout=logfile, stderr=subprocess.STDOUT)
        stopped = threading.Event()
        hardware = None
        payload = None
        payload_file = None
        try:
            if mode not in ("normal", "backpressure"):
                proc.wait(timeout=5)
                assert proc.returncode != 0
                logfile.seek(0)
                expected = {"no-coherency": "does not advertise coherent",
                            "bad-abi": "ABI is missing", "bad-config": "requires only",
                            "overlap": "regions overlap"}[mode]
                assert expected in logfile.read()
                return

            def emulate_fifo():
                while not stopped.wait(0.00005):
                    ticket = get(user, FIFO + 12)
                    if get(user, FIFO + 8) and get(user, FIFO + 16) == ticket:
                        put(user, FIFO + 8, 0)
                        put(user, FIFO + 12, ticket + 1)

            if not QDMA:
                hardware = threading.Thread(target=emulate_fifo)
                hardware.start()
            wait(lambda: get(user, MBX + 0x30) == 3, proc, "startup")
            endpoint = ECAM + 3 * 4096
            assert struct.unpack_from("<HH", user, endpoint) == (0x8086, 0x10fb)
            number = 0

            def publish(wire):
                nonlocal produced
                wait(lambda: produced - get(cq, 4080) < 7, proc, "host ring credit")
                if BRIDGE:
                    index = 64 + (produced % 8) * 64
                    cq[index:index + 32] = wire
                    produced += 1
                    put(cq, 0, produced)
                    return produced
                index = (produced % 8) * 64
                cq[index + 8:index + 40] = wire
                # Publish color last, as the DMA completion validity indicator.
                color = (1 ^ ((produced // 8) & 1)) << 1
                produced += 1
                put(cq, 4088, produced)
                cq[index] = color
                ATOMIC.scope_test_store16(ctypes.addressof(ctypes.c_char.from_buffer(cq, 8 * 64)), produced % 8)
                return produced

            def packet(kind, offset, value=0):
                nonlocal number
                number += 1
                if not QDMA:
                    wait(lambda: get(user, FIFO + 8) == 0, proc, "FIFO empty")
                ticket = get(user, FIFO + 12)
                lane = value if kind == 1 else value << ((offset & 7) * 8)
                flags = 0x300 | (4 << 20)
                flags |= (7 << 16) if kind == 1 else 0
                flags |= (0xf if kind == 1 else (0 if kind == 3 else 0xf << (offset & 7))) << 24
                wire = struct.pack("<8I", 0x5844504b, kind, flags, 32, number,
                                   offset, lane & 0xffffffff, lane >> 32)
                old_control = get(user, MBX + 0x3c)
                if QDMA:
                    target = publish(wire)
                else:
                    user[FIFO + 32:FIFO + 64] = wire
                    put(user, FIFO + 8, 1)
                if kind == 1:
                    wait(lambda: get(user, MBX + 0x10) == number, proc, "config ACK")
                else:
                    wait(lambda: get(user, MBX + 0x38) == number and
                         get(user, MBX + 0x3c) != old_control, proc, "BAR response")
                    assert get(user, MBX + 0x3c) & 3 == 0, hex(offset)
                if QDMA:
                    wait(lambda: get(cq, 4080) >= target, proc, "QDMA credit return")
                    if kind == 2:
                        done = bytearray(wire)
                        struct.pack_into("<I", done, 4, 4)
                        target = publish(done)
                        wait(lambda: get(cq, 4080) >= target, proc, "BAR WRITE_DONE")
                else:
                    wait(lambda: get(user, FIFO + 12) != ticket, proc, "ordered POP")
                result = get(user, MBX + 0x34) | (get(user, MBX + 0x4c) << 32)
                return result >> ((offset & 7) * 8)

            packet(1, 0x10, 0x50000000)
            packet(1, 4, 6)
            assert packet(3, 0x42a4) & 0x40000000
            packet(2, 0x880, 1)  # queue-0 interrupt unmask
            payload_file = (root / "bypass").open("r+b")
            payload = mmap.mmap(payload_file.fileno(), 0x10000, offset=ALIAS + GUEST)
            tx_desc, tx_buffer = GUEST + 0x1000, GUEST + 0x2000
            frame = bytes.fromhex("ffffffffffff02585341490188b5") + bytes(range(46))
            payload[0x2000:0x2000 + len(frame)] = frame
            struct.pack_into("<QII", payload, 0x1000, tx_buffer,
                             0x0b300000 | len(frame), 0)
            for offset, value in ((0x6000, tx_desc), (0x6004, 0), (0x6008, 128),
                                  (0x6028, 0x2000000), (0x4a80, 1)):
                packet(2, offset, value)
            packet(1, 4, 2)  # no DMA while guest Bus Master Enable is clear
            packet(2, 0x6018, 1)
            time.sleep(0.01)
            assert not get(payload, 0x100c) & 1
            packet(1, 4, 6)
            assert tap_peer.recv(65536) == frame
            wait(lambda: get(payload, 0x100c) & 1, proc, "TX descriptor DD")
            wait(lambda: get(user, MBX + 0x50) == 1, proc, "TX INTx")
            assert packet(3, 0x800) & 1
            wait(lambda: get(user, MBX + 0x50) == 0, proc, "INTx clear")

            rx_desc, rx_buffer = GUEST + 0x3000, GUEST + 0x4000
            struct.pack_into("<QQ", payload, 0x3000, rx_buffer, 0)
            for offset, value in ((0x1000, rx_desc), (0x1004, 0), (0x1008, 128),
                                  (0x1028, 0x2000000), (0x3000, 1), (0x1018, 1)):
                packet(2, offset, value)
            tap_peer.send(frame)
            wait(lambda: get(payload, 0x3008) & 3 == 3, proc, "RX DD/EOP")
            assert payload[0x4000:0x4000 + len(frame)] == frame
            assert struct.unpack_from("<H", payload, 0x300c)[0] == len(frame)
            wait(lambda: get(user, MBX + 0x50) == 1, proc, "RX INTx")
            assert packet(3, 0x800) & 1
            packet(2, 0, 0x4000000)  # reset clears queue state
            assert packet(3, 0x6010) == 0
            assert packet(3, 0x1010) == 0
            if QDMA:
                for _ in range(300):
                    assert packet(3, 0x42a4) & 0x40000000
                assert produced == get(cq, 4080)
        except Exception:
            logfile.seek(0)
            print(logfile.read(), file=sys.stderr)
            raise
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=5)
            stopped.set()
            if hardware:
                hardware.join()
            if payload:
                payload.close()
            if payload_file:
                payload_file.close()
            user.close()
            user_file.close()
            tap_peer.close()
            tap_backend.close()
            logfile.close()
            if cq:
                cq.close()
            if cq_file:
                cq_file.close()


for case in ("normal", "backpressure", "no-coherency", "bad-abi", "bad-config", "overlap"):
    run(case)
    print(f"PASS: {TRANSPORT} host proxy {case}")
