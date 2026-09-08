#!/usr/bin/env python3
"""Deterministic Xcode project generation using the Python standard library."""
from pathlib import Path
import hashlib,json
ROOT=Path(__file__).resolve().parent.parent
def ident(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(str(s))
def main():
    objects={}
    def put(name,text):
        key=ident(name);objects[key]=text;return key
    refs=[];builds=[];resources=[]
    sources=sorted([*ROOT.glob('App/*.swift'),*ROOT.glob('Core/*.swift')])
    for p in sources:
        rel=p.relative_to(ROOT).as_posix()
        ref=put('ref:'+rel,'{ isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+q(rel)+'; sourceTree = "<group>"; }')
        refs.append(ref);builds.append(put('build:'+rel,'{ isa = PBXBuildFile; fileRef = '+ref+'; }'))
    for rel,kind in [('App/Assets.xcassets','folder.assetcatalog'),('App/PrivacyInfo.xcprivacy','text.xml')]:
        ref=put('ref:'+rel,'{ isa = PBXFileReference; lastKnownFileType = '+kind+'; path = '+q(rel)+'; sourceTree = "<group>"; }')
        refs.append(ref);resources.append(put('build:'+rel,'{ isa = PBXBuildFile; fileRef = '+ref+'; }'))
    refs.append(put('info','{ isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "App/Info.plist"; sourceTree = "<group>"; }'))
    product=put('product','{ isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HorizonCamera.app; sourceTree = BUILT_PRODUCTS_DIR; }')
    products=put('products','{ isa = PBXGroup; children = ('+product+',); name = Products; sourceTree = "<group>"; }')
    group=put('group','{ isa = PBXGroup; children = ('+','.join(refs+[products])+',); sourceTree = "<group>"; }')
    phase=put('sources','{ isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+',); runOnlyForDeploymentPostprocessing = 0; }')
    resource=put('resources','{ isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(resources)+',); runOnlyForDeploymentPostprocessing = 0; }')
    framework=put('frameworks','{ isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
    pcs=[];tcs=[]
    for config in ['Debug','Release']:
        ps={'ALWAYS_SEARCH_USER_PATHS':'NO','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
            'IPHONEOS_DEPLOYMENT_TARGET':'17.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'minimal',
            'ENABLE_USER_SCRIPT_SANDBOXING':'YES','DEBUG_INFORMATION_FORMAT':'dwarf' if config=='Debug' else 'dwarf-with-dsym',
            'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O',
            'SWIFT_COMPILATION_MODE':'incremental' if config=='Debug' else 'wholemodule'}
        if config=='Debug':ps['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
        ts={'PRODUCT_BUNDLE_IDENTIFIER':'app.eyad.HorizonCamera','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'App/Info.plist',
            'GENERATE_INFOPLIST_FILE':'NO','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
            'SUPPORTS_MACCATALYST':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
            'MARKETING_VERSION':'1.0.0','CURRENT_PROJECT_VERSION':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':'',
            'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','SWIFT_EMIT_LOC_STRINGS':'NO','ENABLE_BITCODE':'NO'}
        def cf(s):return '{ isa = XCBuildConfiguration; buildSettings = { '+''.join(k+' = '+q(v)+'; ' for k,v in s.items())+'}; name = '+config+'; }'
        pcs.append(put('project:'+config,cf(ps)));tcs.append(put('target:'+config,cf(ts)))
    pc=put('pc','{ isa = XCConfigurationList; buildConfigurations = ('+','.join(pcs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
    tc=put('tc','{ isa = XCConfigurationList; buildConfigurations = ('+','.join(tcs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }')
    target=put('app','{ isa = PBXNativeTarget; buildConfigurationList = '+tc+'; buildPhases = ('+','.join([phase,framework,resource])+',); buildRules = (); dependencies = (); name = HorizonCamera; productName = HorizonCamera; productReference = '+product+'; productType = "com.apple.product-type.application"; }')
    project=put('project','{ isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = { '+target+' = { CreatedOnToolsVersion = 26.0; }; }; }; buildConfigurationList = '+pc+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = '+group+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = ('+target+',); }')
    out=ROOT/'HorizonCamera.xcodeproj';out.mkdir(exist_ok=True)
    text='// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
    text+='\n'.join(k+' = '+v+';' for k,v in sorted(objects.items()))+'\n}; rootObject = '+project+'; }\n'
    (out/'project.pbxproj').write_text(text)
    scheme_dir=out/'xcshareddata/xcschemes';scheme_dir.mkdir(parents=True,exist_ok=True)
    ref='<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="'+target+'" BuildableName="HorizonCamera.app" BlueprintName="HorizonCamera" ReferencedContainer="container:HorizonCamera.xcodeproj"/>'
    scheme='<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">'+ref+'</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+ref+'</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">'+ref+'</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>\n'
    (scheme_dir/'HorizonCamera.xcscheme').write_text(scheme)
    print('Generated Xcode project:',len(sources),'Swift files')
if __name__=='__main__':main()
