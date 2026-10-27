"""Package an already compiled Lab build, preserving MIT notices and resources."""
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
products = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
app = output / "接口线缆助手.app"
identifier = "local.leo.WhatCableLab"
output.mkdir(parents=True, exist_ok=True)
if app.exists():
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != identifier:
        raise SystemExit("Refusing to overwrite an application with a different identity")
    shutil.rmtree(app)
contents = app / "Contents"
for directory in ("MacOS", "Helpers", "Resources", "PlugIns"):
    (contents / directory).mkdir(parents=True)
shutil.copy2(products / "WhatCable", contents / "MacOS/WhatCable")
shutil.copy2(products / "whatcable-cli", contents / "Helpers/whatcable")
widget_source = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else None
if widget_source is None or not widget_source.is_dir():
    raise SystemExit("A built LabDesktopWidget.appex is required")
widget = contents / "PlugIns/LabDesktopWidget.appex"
shutil.copytree(widget_source, widget)
for bundle in products.glob("*.bundle"):
    shutil.copytree(bundle, contents / "Resources" / bundle.name)
shutil.copy2(repo / "scripts/AssistantIcon.icns", contents / "Resources/AppIcon.icns")
for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md", "NOTICE.md"):
    shutil.copy2(repo / notice, contents / "Resources" / notice)
(contents / "Resources/Lab-NOTICE.txt").write_text(
    "接口线缆助手: independent extensions built from public MIT sources.\n"
    "Upstream WhatCable copyright 2026 Darryl Morley.\n"
    "Lab additions copyright 2026 Leo. Licensed under the MIT terms in LICENSE.\n"
    "No proprietary Pro plugin, licence keys, or purchase-state modifications are included.\n"
    "Includes an independently built, sandboxed Lab WidgetKit extension.\n"
    "No official updater is bundled with this local build.\n", encoding="utf-8")
info = {
    "CFBundleName": "接口线缆助手", "CFBundleDisplayName": "接口线缆助手",
    "CFBundleExecutable": "WhatCable", "CFBundleIdentifier": identifier,
    "CFBundlePackageType": "APPL", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "10001",
    "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "15.0",
    "LSUIElement": True, "NSHighResolutionCapable": True,
    "LSApplicationCategoryType": "public.app-category.utilities",
    "CFBundleDevelopmentRegion": "zh-Hans", "CFBundleLocalizations": ["zh-Hans", "en"],
    "NSHumanReadableCopyright": "WhatCable © 2026 Darryl Morley; independent Lab extensions © 2026 Leo",
    "WhatCableLabBuild": True,
    "CFBundleURLTypes": [{"CFBundleURLName": "接口线缆助手", "CFBundleURLSchemes": ["whatcable-lab"]}],
}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
for lang in ("zh-Hans", "en"):
    (contents / "Resources" / (lang + ".lproj")).mkdir()
# Finder can attach these to intermediate resource bundles; they are not
# program data and cause strict signature verification to reject a build.
for attribute in ("com.apple.FinderInfo", "com.apple.ResourceFork"):
    subprocess.run(["/usr/bin/xattr", "-dr", attribute, str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(contents / "Helpers/whatcable")], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements",
    str(repo / "scripts/LabDesktopWidget.entitlements"), str(widget)], check=True)
subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
