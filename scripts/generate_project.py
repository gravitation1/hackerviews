#!/usr/bin/env python3
"""Generate the dependency-free, shared-source Mac/iPhone Xcode project."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1]
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(s)
objects = {}
def obj(key, value): objects[uid(key)] = value; return uid(key)
files = sorted((root/'HackerViews').rglob('*.swift'))
refs=[]; builds=[]
for f in files:
    path = str(f.relative_to(root))
    ref = obj(path, '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = '+q(path)+'; sourceTree = SOURCE_ROOT; }')
    refs.append(ref)
    builds.append(obj('build:'+path, '{isa = PBXBuildFile; fileRef = '+ref+'; }'))
resource='HackerViews/Resources/filter.js'
resref=obj(resource, '{isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = '+q(resource)+'; sourceTree = SOURCE_ROOT; }')
refs.append(resref)
resbuild=obj('build:'+resource, '{isa = PBXBuildFile; fileRef = '+resref+'; }')
assetref=obj('assets', '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = HackerViews/Resources/Assets.xcassets; sourceTree = SOURCE_ROOT; }')
refs.append(assetref)
assetbuild=obj('build:assets', '{isa = PBXBuildFile; fileRef = '+assetref+'; }')
product=obj('product','{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = HackerViews.app; sourceTree = BUILT_PRODUCTS_DIR; }')
products=obj('products','{isa = PBXGroup; children = ('+product+',); name = Products; sourceTree = "<group>"; }')
group=obj('main','{isa = PBXGroup; children = ('+','.join(refs+[products])+',); sourceTree = "<group>"; }')
sources=obj('sources','{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ('+','.join(builds)+',); runOnlyForDeploymentPostprocessing = 0; }')
resources=obj('resources','{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ('+resbuild+','+assetbuild+',); runOnlyForDeploymentPostprocessing = 0; }')
frameworks=obj('frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
common={
 'PRODUCT_BUNDLE_IDENTIFIER':'$(HACKER_VIEWS_BUNDLE_ID)','PRODUCT_NAME':'HackerViews',
 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
 'SWIFT_VERSION':'6.0','SWIFT_STRICT_CONCURRENCY':'complete',
 'MACOSX_DEPLOYMENT_TARGET':'14.0','IPHONEOS_DEPLOYMENT_TARGET':'17.0',
 'SUPPORTED_PLATFORMS':'macosx iphoneos iphonesimulator','SDKROOT':'auto',
 'TARGETED_DEVICE_FAMILY':'1,2','SUPPORTS_MACCATALYST':'NO',
 'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_FILE':'Config/Info.plist',
 'INFOPLIST_KEY_CFBundleDisplayName':'HackerViews',
 'INFOPLIST_KEY_LSApplicationCategoryType':'public.app-category.news',
 'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES',
 'INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
 'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone':'UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
 'CODE_SIGN_STYLE':'Automatic','CODE_SIGN_ENTITLEMENTS':'Config/Local.entitlements',
 'CODE_SIGN_ENTITLEMENTS[sdk=iphone*]':'Config/Local-iOS.entitlements',
 'HACKER_VIEWS_CLOUD_ENABLED':'NO',
 'CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0',
 'ENABLE_HARDENED_RUNTIME':'YES','ENABLE_APP_SANDBOX':'YES','ENABLE_USER_SELECTED_FILES':'readwrite',
 'ENABLE_OUTGOING_NETWORK_CONNECTIONS':'YES','COMBINE_HIDPI_IMAGES':'YES',
 'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @executable_path/../Frameworks',
}
localconfig=obj('localconfig','{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config/Signing.xcconfig; sourceTree = SOURCE_ROOT; }')
for scope in ['project','target']:
 configs=[]
 for name in ['Debug','Release','CloudDebug','CloudRelease']:
  settings=common.copy() if scope=='target' else {'CLANG_ENABLE_MODULES':'YES','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if 'Debug' in name else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if 'Debug' in name else 'dwarf-with-dsym'}
  if scope=='target' and name.startswith('Cloud'):
   settings.update({'HACKER_VIEWS_CLOUD_ENABLED':'YES','CODE_SIGN_ENTITLEMENTS':'Config/Cloud.entitlements','CODE_SIGN_ENTITLEMENTS[sdk=iphone*]':'Config/Cloud-iOS.entitlements'})
  if 'Debug' in name: settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
  config='{isa = XCBuildConfiguration; name = '+q(name)+'; '+ ('baseConfigurationReference = '+localconfig+'; ' if scope=='target' else '')+'buildSettings = {'+' '.join(q(k)+' = '+q(v)+';' for k,v in settings.items())+'}; }'
  configs.append(obj(scope+name,config))
 obj(scope+'configlist','{isa = XCConfigurationList; buildConfigurations = ('+','.join(configs)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; }')
target=obj('target','{isa = PBXNativeTarget; buildConfigurationList = '+uid('targetconfiglist')+'; buildPhases = ('+','.join([sources,frameworks,resources])+',); buildRules = (); dependencies = (); name = HackerViews; productName = HackerViews; productReference = '+product+'; productType = "com.apple.product-type.application"; }')
project=obj('project','{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }; buildConfigurationList = '+uid('projectconfiglist')+'; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = '+group+'; productRefGroup = '+products+'; projectDirPath = ""; projectRoot = ""; targets = ('+target+',); }')
(root/'HackerViews.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = '+v+';' for k,v in objects.items())+'\n}; rootObject = '+project+'; }\n')
for name,debug,release in [('HackerViews','Debug','Release'),('HackerViews Cloud','CloudDebug','CloudRelease')]:
 ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="HackerViews.app" BlueprintName="HackerViews" ReferencedContainer="container:HackerViews.xcodeproj"/>'
 xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="{debug}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables/></TestAction>
<LaunchAction buildConfiguration="{debug}" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="{release}" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="{debug}"/><ArchiveAction buildConfiguration="{release}" revealArchiveInOrganizer="YES"/>
</Scheme>'''
 (root/f'HackerViews.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme').write_text(xml)
