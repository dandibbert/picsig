#!/usr/bin/env python3
"""Deterministic Xcode project generation. Python standard library; no XcodeGen dependency."""
from pathlib import Path
import hashlib
import json
import plistlib
import struct
import zlib
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent

def generate_app_icon():
    """Generate a deterministic opaque 1024×1024 PNG; no binary asset needs to live in git."""
    width = height = 1024
    rows = bytearray()
    def inside_round_rect(x, y, x0, y0, x1, y1, radius):
        if x0 + radius <= x <= x1 - radius or y0 + radius <= y <= y1 - radius:
            return x0 <= x <= x1 and y0 <= y <= y1
        cx = x0 + radius if x < x0 + radius else x1 - radius
        cy = y0 + radius if y < y0 + radius else y1 - radius
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2
    for y in range(height):
        rows.append(0)  # PNG filter: None
        t = y / (height - 1)
        br = int(82 + 28 * t); bg = int(62 + 18 * t); bb = int(194 + 32 * t)
        for x in range(width):
            r, g, b = br, bg, bb
            # Three paper strips imply stitching; no transparency is used.
            if inside_round_rect(x, y, 208, 190, 816, 420, 74): r, g, b = 238, 235, 255
            if inside_round_rect(x, y, 158, 397, 766, 627, 74): r, g, b = 210, 250, 241
            if inside_round_rect(x, y, 258, 604, 866, 834, 74): r, g, b = 255, 226, 234
            # Privacy shield / eye-slash motif in the center.
            dx, dy = x - 512, y - 512
            if dx * dx + dy * dy <= 108 * 108: r, g, b = 35, 31, 73
            if abs((x - 512) + (y - 512)) < 18 and 390 < x < 634 and 390 < y < 634: r, g, b = 255, 255, 255
            rows.extend((r, g, b))
    def chunk(kind, data):
        payload = kind + data
        return struct.pack('>I', len(data)) + payload + struct.pack('>I', zlib.crc32(payload) & 0xffffffff)
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b''))
    target = ROOT / 'App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(png)

generate_app_icon()
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(key_name, isa, **fields):
    key = uid(key_name); objects[key] = dict(isa=isa, **fields); return key

def encode(value, level=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(level+1)+json.dumps(str(k))+ ' = '+encode(v,level+1)+';\n' for k,v in value.items()) + '\t'*level+'}'
    if isinstance(value, list): return '(\n'+''.join('\t'*(level+1)+encode(v,level+1)+',\n' for v in value)+'\t'*level+')'
    return json.dumps(str(value),ensure_ascii=False)

def fileref(path, kind=None):
    ext=Path(path).suffix
    kind=kind or {'.swift':'sourcecode.swift','.plist':'text.plist.xml','.xcprivacy':'text.xml','.xcassets':'folder.assetcatalog'}.get(ext,'text')
    return add('file:'+path,'PBXFileReference',lastKnownFileType=kind,path=path,sourceTree='<group>')
def phase(name, files, kind):
    builds=[add('build:'+name+':'+path,'PBXBuildFile',fileRef=fileref(path)) for path in files]
    return add('phase:'+name,'PBX'+kind+'BuildPhase',buildActionMask='2147483647',files=builds,runOnlyForDeploymentPostprocessing='0')
def configurations(name, shared, extra=None):
    values=[]
    for config in ['Debug','Release']:
        settings=dict(shared)
        if name=='Project':
            settings.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if config=='Debug' else '-O',DEBUG_INFORMATION_FORMAT='dwarf' if config=='Debug' else 'dwarf-with-dsym')
            if config=='Debug': settings.update(ENABLE_TESTABILITY='YES',SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG',GCC_PREPROCESSOR_DEFINITIONS=['DEBUG=1','$(inherited)'],ONLY_ACTIVE_ARCH='YES')
            else: settings['SWIFT_COMPILATION_MODE']='wholemodule'
        if extra: settings.update(extra.get(config,{}))
        values.append(add('config:'+name+config,'XCBuildConfiguration',name=config,buildSettings=settings))
    return add('configlist:'+name,'XCConfigurationList',buildConfigurations=values,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

appfiles=sorted(str(p.relative_to(ROOT)) for folder in ['Sources/PicSigCore','App'] for p in (ROOT/folder).rglob('*.swift'))
resources=['App/Resources/Assets.xcassets','App/Resources/PrivacyInfo.xcprivacy']
testfiles=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Tests/PicSigAppTests').glob('*.swift'))
uifiles=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Tests/PicSigUITests').glob('*.swift'))
project_id=uid('project')
products=[]; targets=[]
for name,files,producttype in [('PicSig',appfiles,'com.apple.product-type.application'),('PicSigAppTests',testfiles,'com.apple.product-type.bundle.unit-test'),('PicSigUITests',uifiles,'com.apple.product-type.bundle.ui-testing')]:
    product=add('product:'+name,'PBXFileReference',explicitFileType='wrapper.application' if name=='PicSig' else 'wrapper.cfbundle',includeInIndex='0',path=name+('.app' if name=='PicSig' else '.xctest'),sourceTree='BUILT_PRODUCTS_DIR'); products.append(product)
    phases=[phase(name+':sources',files,'Sources'),phase(name+':frameworks',[],'Frameworks'),phase(name+':resources',resources if name=='PicSig' else [],'Resources')]
    settings=dict(PRODUCT_NAME='$(TARGET_NAME)',PRODUCT_BUNDLE_IDENTIFIER='com.dandibbert.picsig.astra'+('' if name=='PicSig' else '.'+name),TARGETED_DEVICE_FAMILY='1,2',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',SUPPORTS_MACCATALYST='NO',SWIFT_VERSION='5.0',SWIFT_STRICT_CONCURRENCY='minimal',CODE_SIGN_STYLE='Automatic',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'])
    deps=[]
    if name=='PicSig':
        settings.update(INFOPLIST_FILE='App/Resources/Info.plist',GENERATE_INFOPLIST_FILE='NO',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon',ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME='AccentColor',MARKETING_VERSION='0.1.0',CURRENT_PROJECT_VERSION='1',ENABLE_PREVIEWS='YES',PRODUCT_MODULE_NAME='PicSig')
    else:
        settings.update(GENERATE_INFOPLIST_FILE='YES',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks'])
        proxy=add('proxy:'+name,'PBXContainerItemProxy',containerPortal=project_id,proxyType='1',remoteGlobalIDString=uid('target:PicSig'),remoteInfo='PicSig')
        deps=[add('dependency:'+name,'PBXTargetDependency',target=uid('target:PicSig'),targetProxy=proxy)]
        if name=='PicSigAppTests':settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/PicSig.app/PicSig',BUNDLE_LOADER='$(TEST_HOST)')
        else:settings.update(TEST_TARGET_NAME='PicSig')
    targets.append(add('target:'+name,'PBXNativeTarget',buildConfigurationList=configurations(name,settings),buildPhases=phases,buildRules=[],dependencies=deps,name=name,productName=name,productReference=product,productType=producttype))

appgroup=add('group:app','PBXGroup',name='Application',children=[uid('file:'+f) for f in appfiles]+[uid('file:'+f) for f in resources]+[fileref('App/Resources/Info.plist')],sourceTree='<group>')
testgroup=add('group:tests','PBXGroup',name='Tests',children=[uid('file:'+f) for f in testfiles+uifiles],sourceTree='<group>')
productgroup=add('group:products','PBXGroup',name='Products',children=products,sourceTree='<group>')
main=add('group:main','PBXGroup',children=[appgroup,testgroup,productgroup],sourceTree='<group>')
shared=dict(ALWAYS_SEARCH_USER_PATHS='NO',CLANG_ENABLE_MODULES='YES',CLANG_ENABLE_OBJC_ARC='YES',CLANG_WARN_DOCUMENTATION_COMMENTS='YES',GCC_C_LANGUAGE_STANDARD='gnu17',IPHONEOS_DEPLOYMENT_TARGET='17.0',SDKROOT='iphoneos',ENABLE_USER_SCRIPT_SANDBOXING='YES',SWIFT_VERSION='5.0')
add('project','PBXProject',attributes=dict(BuildIndependentTargetsInParallel='YES',LastUpgradeCheck='1600',LastSwiftUpdateCheck='1600',TargetAttributes={uid('target:'+n):dict(CreatedOnToolsVersion='16.0',**({} if n=='PicSig' else {'TestTargetID':uid('target:PicSig')})) for n in ['PicSig','PicSigAppTests','PicSigUITests']}),buildConfigurationList=configurations('Project',shared),compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',hasScannedForEncodings='0',knownRegions=['zh-Hans','en','Base'],mainGroup=main,productRefGroup=productgroup,projectDirPath='',projectRoot='',targets=targets)
project=ROOT/'PicSig.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project_id))+'\n')

def buildable(name):
    product=name+('.app' if name=='PicSig' else '.xctest')
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target:"+name)}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:PicSig.xcodeproj"/>'
scheme=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('PicSig')}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO" parallelizable="NO">{buildable('PicSigAppTests')}</TestableReference><TestableReference skipped="NO" parallelizable="NO">{buildable('PicSigUITests')}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('PicSig')}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('PicSig')}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True);(schemes/'PicSig.xcscheme').write_text(scheme)
print(f'Generated project: {len(appfiles)} application sources, {len(testfiles)} image test files, {len(uifiles)} UI test files.')
