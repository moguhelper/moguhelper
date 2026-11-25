#!/bin/zsh
# 打包 MoguHelper.app。
#   ./build-app.sh          自用版 → build/MoguHelper.app（有 private/data 就带上里面的资料，绝不能发给别人）
#   ./build-app.sh dist     公开版 → dist/MoguHelper.app 和 dist/MoguHelper.zip（只用仓库里的文件；不动正在用的自用版）
#   ./build-app.sh test     和公开版一样，但用另一个程序标识和数据目录，模拟从没用过的新用户 → build/test/MoguHelper.app
set -e
cd "$(dirname "$0")"
MODE="${1:-personal}"
case "$MODE" in
  personal) FINAL=build/MoguHelper.app; ID=app.moguhelper ;;
  dist)     FINAL=dist/MoguHelper.app; ID=app.moguhelper ;;
  test)     FINAL=build/test/MoguHelper.app; ID=app.moguhelper.test ;;
  *) echo "用法: $0 [personal|dist|test]"; exit 1 ;;
esac
swift build -c release --product ChatTranslator
swift build -c release --product ocr-helper
# 先在旁边打包、签好名再换进去：旧版还在运行时直接改它的文件，系统会当成没授权的新程序，弹“想要录制屏幕”
APP=build/.stage/MoguHelper.app
rm -rf build/.stage
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$(dirname "$FINAL")"
cp .build/release/ChatTranslator "$APP/Contents/MacOS/ChatTranslator"
cp .build/release/ocr-helper "$APP/Contents/MacOS/ocr-helper"
# 发给别人的：去掉调试信息（里面有本机文件夹路径）
if [ "$MODE" = dist ]; then strip -S -x "$APP/Contents/MacOS/ChatTranslator" "$APP/Contents/MacOS/ocr-helper" 2>/dev/null; fi
for f in Glossary Quests QuestNames Items Maps ItemSources QuestTips Glyphs; do cp Sources/TranslatorCore/$f.json "$APP/Contents/Resources/$f.json"; done
if [ "$MODE" = personal ] && [ -d private/data ]; then python3 -I private/overlay.py "$APP/Contents/Resources"; fi
# 程序图标（由 tools/make_icon.swift 生成）
cp Assets/Mushroom.png "$APP/Contents/Resources/Mushroom.png"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>MoguHelper</string>
  <key>CFBundleDisplayName</key><string>MoguHelper</string>
  <key>CFBundleExecutable</key><string>ChatTranslator</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>app.moguhelper.pack</string>
    <key>UTTypeDescription</key><string>MoguHelper 资料</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mogu</string></array></dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>MoguHelper 资料</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>app.moguhelper.pack</string></array>
  </dict></array>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 没有证书就用临时签名（每次重新打包要重新授权屏幕录制）；有开发者证书：SIGN_ID="Developer ID Application: …" ./build-app.sh
# 本机固定证书放在 signing/sign.sh（不进仓库）：里面设 SIGN_ID，需要时解锁钥匙串
[ -f signing/sign.sh ] && source signing/sign.sh
KCARG=("${KCARG[@]}")
SIGN="${SIGN_ID:--}"
codesign --force "${KCARG[@]}" --sign "$SIGN" --identifier $ID.ocr-helper "$APP/Contents/MacOS/ocr-helper"
codesign --force "${KCARG[@]}" --sign "$SIGN" --identifier $ID "$APP"
codesign --verify --strict "$APP"
# 公开版：资料文件必须和仓库里的空表一模一样，不能多出别的
if [ "$MODE" != personal ]; then
  for f in "$APP"/Contents/Resources/*; do
    n=$(basename "$f")
    case "$n" in
      Mushroom.png|AppIcon.icns) cmp -s "$f" "Assets/$n" || { echo "❌ $n 不对"; exit 1; } ;;
      Glossary.json|Quests.json|QuestNames.json|Items.json|Maps.json|ItemSources.json|QuestTips.json|Glyphs.json)
        cmp -s "$f" "Sources/TranslatorCore/$n" || { echo "❌ $n 不是仓库里的"; exit 1; } ;;
      *) echo "❌ 公开版里不该有 $n"; exit 1 ;;
    esac
  done
  for n in Items Maps Quests; do [ $(stat -f %z "Sources/TranslatorCore/$n.json") -lt 200 ] || { echo "❌ 仓库里的 $n.json 不是空表"; exit 1; }; done
fi
if [ "$MODE" = personal ]; then
  pkill -f "moguhelper/build/MoguHelper.app/Contents/MacOS/ChatTranslator" || true
  for i in {1..20}; do pgrep -f "moguhelper/build/MoguHelper.app/Contents/MacOS/ChatTranslator" >/dev/null || break; sleep 0.2; done
fi
rm -rf "$FINAL"; mv "$APP" "$FINAL"; rm -rf build/.stage
touch "$FINAL"   # 让访达刷新图标
if [ "$MODE" = dist ]; then rm -f dist/MoguHelper.zip; ditto -c -k --norsrc --noextattr --noacl --keepParent "$FINAL" dist/MoguHelper.zip; fi
echo "已生成（$MODE）：$(pwd)/$FINAL"
