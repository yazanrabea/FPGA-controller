"""Stand-in for `xsdb scripts/jtag_server.tcl` in test_jtag.py (no Vivado, no board).

Speaks the same line protocol on 127.0.0.1 and prints "READY <port>" like the real one,
then FLOODS its stdout before serving: if XsdbScanPort didn't keep reading xsdb's output,
the pipe would fill, this process would block in print(), and the scan would never be
answered. A scan is answered with the inverse of the bytes sent (like jtag_echo_core).
"""
import socket
import sys

srv = socket.socket()
srv.bind(("127.0.0.1", 0))
srv.listen(1)
print(f"READY {srv.getsockname()[1]}", flush=True)
for i in range(20000):                      # ~1.4 MB, far more than any pipe buffer
    print(f"noise line {i:06d} from the fake xsdb ......................", flush=False)
sys.stdout.flush()
conn, _ = srv.accept()
f = conn.makefile("rw", encoding="ascii", newline="\n")
for line in f:
    if line.startswith("S "):
        data = bytes.fromhex(line[2:].strip())
        f.write(bytes(b ^ 0xFF for b in data).hex().upper() + "\n")
        f.flush()
    elif line.startswith("Q"):
        f.write("BYE\n")
        f.flush()
        break
conn.close()
