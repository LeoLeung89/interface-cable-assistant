"""Build a native sandboxed WidgetKit extension using the installed Xcode.

The project is generated into the build directory, without XcodeGen or new
third-party dependencies. Local builds are ad-hoc signed at packaging time.
"""
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
build = Path(sys.argv[1]).resolve()
project = build / "widget-project/LabDesktopWidget.xcodeproj"
project.mkdir(parents=True, exist_ok=True)

def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()

objects = {}
def obj(object_key, **values):
    key = uid(object_key)
    objects[key] = values
    return key

files = [repo / "Sources/LabDesktopWidget/LabDesktopWidget.swift",
         repo / "Sources/WhatCableLabWidgetShared/LabWidgetSnapshot.swift"]
refs = [obj("file" + str(i), isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(f), sourceTree="<absolute>") for i, f in enumerate(files)]
sources = [obj("build" + str(i), isa="PBXBuildFile", fileRef=ref) for i, ref in enumerate(refs)]
product = obj("product", isa="PBXFileReference", explicitFileType="wrapper.app-extension", path="LabDesktopWidget.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("products", isa="PBXGroup", children=[product], name="Products", sourceTree="<group>")
group = obj("group", isa="PBXGroup", children=refs + [products], sourceTree="<group>")
source_phase = obj("sources", isa="PBXSourcesBuildPhase", buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
frameworks = obj("frameworks", isa="PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
resources = obj("resources", isa="PBXResourcesBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
settings = {
    "PRODUCT_NAME": "LabDesktopWidget", "PRODUCT_BUNDLE_IDENTIFIER": "local.leo.WhatCableLab.widget",
    "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "15.0", "SWIFT_VERSION": "5.0",
    "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_COMPILATION_MODE": "wholemodule",
    "ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "YES", "SKIP_INSTALL": "YES",
    "APPLICATION_EXTENSION_API_ONLY": "YES", "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": str(repo / "Sources/LabDesktopWidget/Info.plist"),
    "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO", "CODE_SIGN_IDENTITY": "",
    "CODE_SIGN_ENTITLEMENTS": str(repo / "scripts/LabDesktopWidget.entitlements"),
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"],
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "SWIFT_EMIT_LOC_STRINGS": "NO",
    "CLANG_ENABLE_MODULES": "YES", "ENABLE_HARDENED_RUNTIME": "YES",
}
target_config = obj("targetRelease", isa="XCBuildConfiguration", name="Release", buildSettings=settings)
project_config = obj("projectRelease", isa="XCBuildConfiguration", name="Release", buildSettings={})
target_list = obj("targetList", isa="XCConfigurationList", buildConfigurations=[target_config], defaultConfigurationName="Release", defaultConfigurationIsVisible=0)
project_list = obj("projectList", isa="XCConfigurationList", buildConfigurations=[project_config], defaultConfigurationName="Release", defaultConfigurationIsVisible=0)
target = obj("target", isa="PBXNativeTarget", name="LabDesktopWidget", productName="LabDesktopWidget",
    productReference=product, productType="com.apple.product-type.app-extension", buildConfigurationList=target_list,
    buildPhases=[source_phase, frameworks, resources], buildRules=[], dependencies=[])
root = obj("project", isa="PBXProject", attributes={"LastUpgradeCheck": "2700"},
    buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en",
    knownRegions=["en", "Base", "zh-Hans"], hasScannedForEncodings=0, mainGroup=group,
    productRefGroup=products, projectDirPath="", projectRoot="", targets=[target])

def encode(value, indent=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (indent + 1) + json.dumps(str(k)) + " = " + encode(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (indent + 1) + encode(v, indent + 1) + ",\n" for v in value) + "\t" * indent + ")"
    return json.dumps(value, ensure_ascii=False)

(project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({
    "archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": root
}), encoding="utf-8")
subprocess.run(["/usr/bin/xcodebuild", "build", "-project", str(project), "-target", "LabDesktopWidget",
    "-configuration", "Release", "-sdk", "macosx", "SYMROOT=" + str(build / "widget-products"),
    "OBJROOT=" + str(build / "widget-intermediates"), "CODE_SIGNING_ALLOWED=NO"], check=True)
extension = build / "widget-products/Release/LabDesktopWidget.appex"
if not extension.is_dir():
    raise SystemExit("Widget extension was not produced")
print(extension)
