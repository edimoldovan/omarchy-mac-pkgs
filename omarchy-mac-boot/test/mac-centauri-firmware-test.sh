#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"

# omarchy-centauri-ftab builds the N1 image as macOS's centaurid does: manifest after the file table,
# then 'nvrm' and '_cal' unpadded; the initcpio hook adds it under the device tree's firmware-name.
require_command python3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stitcher=$ROOT/files/usr/lib/omarchy/initcpio/omarchy-centauri-ftab
hook=$ROOT/files/etc/initcpio/install/omarchy-centauri
mkdir -p "$work/inputs" "$work/dt/pcie/wifi" "$work/dt-other/pcie"
python3 -I - "$work/inputs" <<'PY'
import struct, sys
inputs = sys.argv[1]
def der(tag, body):
    length = len(body)
    encoded = bytes([length]) if length < 0x80 else bytes([0x82]) + length.to_bytes(2, "big")
    return tag + encoded + body
def private(name):
    number = int.from_bytes(name.encode(), "big")
    encoded = []
    while True:
        encoded.insert(0, (number & 0x7F) | (0x80 if encoded else 0))
        number >>= 7
        if not number:
            break
    return bytes([0xFF] + encoded)
subcontainer = lambda name, data: der(b"\x30", der(b"\x02", name[::-1].encode()) + der(b"\x16", b".") + der(b"\x04", data))
blobs = {"BTCS": b"\x0c\0\0\0BTCSdata", "W2CS": b"\x08\0\0\0W2CS", "WFCS": b"\x0a\0\0\0WFCS!!"}
payload = der(b"\x30", der(b"\x02", b"3CWB") + der(b"\x02", b"\x03\0\x03\0") +
              der(private("SPAY"), der(b"\x31", b"".join(subcontainer(n, d) for n, d in blobs.items()))))
im4p = der(b"\x30", der(b"\x16", b"IM4P") + der(b"\x16", b"BWC3") + der(b"\x16", b"1.0") + der(b"\x04", payload))
open(f"{inputs}/BWC3.img4", "wb").write(der(b"\x30", der(b"\x16", b"IMG4") + im4p))
files = [(b"rkos", b"R" * 6), (b"ccaf", b"C" * 8)]
header = bytearray(0x30)
header[0x20:0x28] = b"rkosftab"
struct.pack_into("<I", header, 0x28, len(files))
position, table, body = 0x30 + 16 * len(files), b"", b""
for tag, data in files:
    table += struct.pack("<4sIII", tag, position, len(data), 0)
    body += data + bytes(-len(data) % 4)
    position += len(data) + (-len(data) % 4)
open(f"{inputs}/ftab.bin", "wb").write(bytes(header) + table + body)
open(f"{inputs}/manifest.im4m", "wb").write(b"M" * 10)
open(f"{inputs}/wifi-antenna-sku-info", "wb").write(bytes.fromhex("01000000000000005833000000000000"))
PY
printf 'apple/centauri/j714c-ftab.bin\0' >"$work/dt/pcie/wifi/firmware-name"
printf 'apple/other.bin\0' >"$work/dt-other/pcie/firmware-name"

"$stitcher" "$work/inputs" "$work/image.bin"
check=$(python3 -I - "$work/image.bin" <<'PY'
import struct, sys
image = open(sys.argv[1], "rb").read()
count = struct.unpack_from("<I", image, 0x28)[0]
offset, length = struct.unpack_from("<II", image, 0x10)
entries = {tag.decode(): (o, l) for tag, o, l, _ in (struct.unpack_from("<4sIII", image, 0x30 + 16 * i) for i in range(count))}
read = lambda tag: image[entries[tag][0]:entries[tag][0] + entries[tag][1]]
calibration = read("_cal")
nvrm = "5376764e77a87c4d2a0000002a000000010000000100000077736b750000000002000000000002005833"
print(count, offset == 0x30 + 16 * count, image[offset:offset + length] == b"M" * 10, read("rkos") == b"R" * 6,
      read("nvrm").hex() == nvrm, entries["_cal"][0] == entries["nvrm"][0] + 42,
      calibration[:4] == b"\3\0\0\0", calibration[0x48:0x50] == struct.pack("<II", 0x100, 8),
      calibration[0x100:] == b"\x08\0\0\0W2CS\x0a\0\0\0WFCS!!\x0c\0\0\0BTCSdata", len(image) == entries["_cal"][0] + len(calibration))
PY
)
[[ $check == "4 True True True True True True True True True" ]] || fail "the image has the manifest, nvrm and _cal where macOS puts them" "$check"
pass "omarchy-centauri-ftab stitches the manifest, nvrm and _cal the way macOS does"

build_hook() {
  EXPECTED=$work/image.bin OMARCHY_CENTAURI_DEVICE_TREE=$1 OMARCHY_CENTAURI_INPUTS=$2 OMARCHY_CENTAURI_FTAB=$stitcher bash -c '
    add_file() { printf "add %s %s\n" "$2" "$(cmp -s "$1" "$EXPECTED" && echo same || echo different)"; }
    warning() { printf "warning %s\n" "$1"; }
    source "$1"
    build
  ' _ "$hook"
}
[[ $(build_hook "$work/dt" "$work/inputs") == "add /lib/firmware/apple/centauri/j714c-ftab.bin same" ]] ||
  fail "the hook adds the image under the device tree's firmware-name" "$(build_hook "$work/dt" "$work/inputs")"
[[ -z $(build_hook "$work/dt-other" "$work/inputs") ]] || fail "a Mac without an N1 gets nothing"
[[ $(build_hook "$work/dt" "$work/missing") == "warning No N1 firmware inputs in $work/missing: Wi-Fi and Bluetooth stay off" ]] ||
  fail "an N1 without inputs warns and adds nothing"
pass "the hook adds the N1 image only where the device tree asks for one and the inputs exist"
