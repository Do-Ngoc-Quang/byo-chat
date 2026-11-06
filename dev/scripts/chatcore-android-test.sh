#!/usr/bin/env bash
# Biên dịch test của chatcore bằng NDK, đẩy vào emulator/thiết bị đang chạy (adb) và chạy.
# Cần: ANDROID_NDK_HOME (hoặc ANDROID_NDK_LATEST_HOME), rustup target, adb có thiết bị.
# Dùng: dev/scripts/chatcore-android-test.sh [x86_64|aarch64]
set -euo pipefail
ARCH="${1:-x86_64}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:?cần ANDROID_NDK_HOME}}"
API=24
case "$ARCH" in
  x86_64)  TRIPLE=x86_64-linux-android ;;
  aarch64) TRIPLE=aarch64-linux-android ;;
  *) echo "arch không hỗ trợ: $ARCH" >&2; exit 2 ;;
esac
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
UP="$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')"
export "CARGO_TARGET_${UP}_LINKER=$BIN/${TRIPLE}${API}-clang"
export "CC_${TRIPLE//-/_}=$BIN/${TRIPLE}${API}-clang"
export "AR_${TRIPLE//-/_}=$BIN/llvm-ar"

cd "$(dirname "$0")/../../chatcore"
rustup target add "$TRIPLE"
mapfile -t EXES < <(cargo test --release --target "$TRIPLE" -p chatcore --no-run --message-format=json \
  | jq -r 'select(.profile.test == true and .executable != null) | .executable')
[ "${#EXES[@]}" -gt 0 ] || { echo "không có file test nào" >&2; exit 1; }

adb shell getconf PAGE_SIZE   # ghi lại cỡ trang (spec nhắc 16 KB)
fail=0
for exe in "${EXES[@]}"; do
  name="$(basename "$exe")"
  adb push "$exe" "/data/local/tmp/$name" >/dev/null
  adb shell "chmod +x /data/local/tmp/$name"
  echo "== $name"
  # adb shell không trả exit code của lệnh trên bản cũ: in thêm mã thoát để bắt.
  out="$(adb shell "/data/local/tmp/$name --test-threads=1; echo EXIT=\$?" 2>&1)" || true
  echo "$out" | tail -25
  echo "$out" | grep -q "EXIT=0" || fail=1
done
exit $fail
