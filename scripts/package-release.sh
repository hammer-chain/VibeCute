#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target_arch="${1:-$(uname -m)}"
[[ "$target_arch" == arm64 || "$target_arch" == x86_64 ]] || exit 2
suffix=""; [[ "$target_arch" == "$(uname -m)" ]] || suffix="/$target_arch"
report_dir="output/release$suffix"
dist_dir="$PWD/dist/release$suffix"
mkdir -p "$report_dir" "$dist_dir"
# A single command owns the fixed profile, app validation and image readback.
bash scripts/build_profile.sh release "$target_arch"
app="$dist_dir/VibeCute.app"
python3 scripts/verify_release.py "$app" --report "$report_dir/bundle-check.json"
bash scripts/release_core_checks.sh "$target_arch" | tee "$report_dir/core-checks.log"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/CodexCaptions" | tr ' ' '-')
dmg="$dist_dir/VibeCute-$version-$build-$arch.dmg"
image_staging=$(mktemp -d "$dist_dir/.dmg.XXXXXX")
mountpoint=$(mktemp -d /tmp/vibecute-dmg.XXXXXX)
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then hdiutil detach "$mountpoint" >/dev/null || true; fi
  rmdir "$mountpoint" 2>/dev/null || true
  rm -rf "$image_staging"
}
trap cleanup EXIT
ditto "$app" "$image_staging/VibeCute.app"
ditto "$app/Contents/Resources/Licenses" "$image_staging/Licenses"
ln -s /Applications "$image_staging/Applications"
hdiutil create -volname VibeCute -srcfolder "$image_staging" -format UDZO -ov "$dmg"
source scripts/signing.sh
codesign --force "${captions_signing_arguments[@]}" "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$dmg"
mounted=1
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]]
python3 scripts/verify_release.py "$mountpoint/VibeCute.app" --report "$report_dir/dmg-readback.json"
diff -r "$mountpoint/Licenses" "$mountpoint/VibeCute.app/Contents/Resources/Licenses"
hdiutil detach "$mountpoint"
mounted=0
python3 - "$dmg" "$report_dir" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1])
report={'dmg':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mounted_readback_verified':True,'legal_documents_verified':True,'notarized':False}
(Path(sys.argv[2]) / 'dmg.json').write_text(json.dumps(report,indent=2)+'\n')
p.with_suffix('.dmg.sha256').write_text(report['sha256']+'  '+p.name+'\n')
print(json.dumps(report,indent=2))
PY
printf 'DMG: %s\n' "$dmg"
