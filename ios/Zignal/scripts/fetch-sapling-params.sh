#!/bin/bash
# Downloads the two Zcash Sapling parameter files (about 51 MB) into Zignal/SaplingParams,
# where Xcode copies them into the app. The Zcash SDK won't build any transaction without
# them; shipping them in the app means nothing is downloaded on a user's phone.
#
# Each file is checked against the size and the SHA-1 and BLAKE2b-512 hashes pinned in the
# Zcash SDK and librustzcash. Anything that doesn't match is deleted. The files are
# gitignored: they are public, large, and anyone can fetch them with this script.
#
# Run from anywhere: scripts/fetch-sapling-params.sh
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="Zignal/SaplingParams"
SOURCE="https://download.z.cash/downloads"

# Prints nothing and succeeds only if the file has the expected size and both hashes.
verify() { # path size sha1 blake2b512
  python3 -I - "$@" <<'PY'
import hashlib, os, sys
path, size, sha1, blake2b = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
if os.path.getsize(path) != size:
    sys.exit(f"{path}: size is {os.path.getsize(path)} bytes, expected {size}")
h1, h2 = hashlib.sha1(), hashlib.blake2b()
with open(path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h1.update(chunk)
        h2.update(chunk)
if h1.hexdigest() != sha1 or h2.hexdigest() != blake2b:
    sys.exit(f"{path}: hash does not match")
PY
}

fetch() { # name size sha1 blake2b512
  local name=$1 out="$DEST/$1"
  if [ -f "$out" ] && verify "$out" "$2" "$3" "$4" 2>/dev/null; then
    echo "$name: already here and verified"
    return
  fi
  rm -f "$out" "$out.part"
  echo "$name: downloading from $SOURCE"
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error \
    --output "$out.part" "$SOURCE/$name"
  if ! verify "$out.part" "$2" "$3" "$4"; then
    rm -f "$out.part"
    echo "$name: deleted, it did not match. Nothing was added to the app." >&2
    exit 1
  fi
  mv "$out.part" "$out"
  echo "$name: verified"
}

mkdir -p "$DEST"
fetch sapling-spend.params 47958396 \
  a15ab54c2888880e53c823a3063820c728444126 \
  8270785a1a0d0bc77196f000ee6d221c9c9894f55307bd9357c3f0105d31ca63991ab91324160d8f53e2bbd3c2633a6eb8bdf5205d822e7f3f73edac51b2b70c
fetch sapling-output.params 3592860 \
  0ebc5a1ef3653948e1c46cf7a16071eac4b7e352 \
  657e3d38dbb5cb5e7dd2970e8b03d69b4787dd907285b5a7f0790dcc8072f60bf593b32cc2d1c030e00ff5ae64bf84c5c3beb84ddc841d48264b4a171744d028
echo "Done. Build the app in Xcode; the files are included automatically."
