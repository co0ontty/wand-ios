#!/usr/bin/env python3
"""Build a scratch UI-test target; never rewrite the checked-out Xcode project."""
import json
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import uuid
import base64
import tempfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[1]
work = pathlib.Path(os.environ.get('LIVE_BACK_BUILD_ROOT', '/Volumes/Wand/Developer/ios/live-native-back'))
project_dir = work/'source'
project_dir.mkdir(parents=True, exist_ok=True)
source_paths=['Wand/App.swift','Wand/ChatDesignPreview.swift','Wand/NativeRootView.swift','Wand/SessionDestinationView.swift','Wand/ChatView.swift','Wand/ConversationViews.swift','Wand/NewConversationView.swift','Wand/ContactsView.swift','Wand/Theme.swift','WandUITests/LiveBackUITests.swift']
def source_hashes(): return {p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in source_paths}
before=source_hashes()
snapshot_id=hashlib.sha256(json.dumps(before,sort_keys=True).encode()).hexdigest()[:12]
for p in source_paths:
    target=work/'verified-sources'/snapshot_id/p
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes((root/p).read_bytes())
project = project_dir/'Wand.xcodeproj'
if not project.exists():
    shutil.copytree(root/'Wand.xcodeproj', project)
# Every source remains the actual working tree, not a substitute implementation.
for name in ['Wand', 'WandWidgets', 'WandTests', 'WandUITests', 'scripts']:
    link = project_dir/name
    if not link.exists(): link.symlink_to(root/name, target_is_directory=True)
raw = work/'project-input.json'
subprocess.run(['plutil','-convert','json','-o',str(raw),str(root/'Wand.xcodeproj/project.pbxproj')],check=True)
data = json.loads(raw.read_text()); objects=data['objects']; main=data['rootObject']; app='A1000000000000000000F700'
def key(n): return f'FDED{n:020X}'
assert all(key(n) not in objects for n in range(1,15))
objects[key(1)]={'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':str(root/'WandUITests/LiveBackUITests.swift'),'sourceTree':'<absolute>'}
objects[key(2)]={'isa':'PBXBuildFile','fileRef':key(1)}
objects[key(3)]={'isa':'PBXFileReference','explicitFileType':'wrapper.cfbundle','includeInIndex':'0','path':'WandLiveBackUITests.xctest','sourceTree':'BUILT_PRODUCTS_DIR'}
objects[key(4)]={'isa':'PBXSourcesBuildPhase','buildActionMask':'2147483647','files':[key(2)],'runOnlyForDeploymentPostprocessing':'0'}
objects[key(5)]={'isa':'PBXFrameworksBuildPhase','buildActionMask':'2147483647','files':[],'runOnlyForDeploymentPostprocessing':'0'}
objects[key(6)]={'isa':'PBXResourcesBuildPhase','buildActionMask':'2147483647','files':[],'runOnlyForDeploymentPostprocessing':'0'}
settings={'CLANG_ENABLE_MODULES':'YES','CODE_SIGN_STYLE':'Automatic','GENERATE_INFOPLIST_FILE':'YES','IPHONEOS_DEPLOYMENT_TARGET':'26.0','PRODUCT_BUNDLE_IDENTIFIER':'com.wand.live-back-uitests','PRODUCT_NAME':'$(TARGET_NAME)','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1,2','TEST_TARGET_NAME':'Wand'}
for n,name in [(7,'Debug'),(8,'Release')]:objects[key(n)]={'isa':'XCBuildConfiguration','buildSettings':settings,'name':name}
objects[key(9)]={'isa':'XCConfigurationList','buildConfigurations':[key(7),key(8)],'defaultConfigurationIsVisible':'0','defaultConfigurationName':'Release'}
objects[key(10)]={'isa':'PBXContainerItemProxy','containerPortal':main,'proxyType':'1','remoteGlobalIDString':app,'remoteInfo':'Wand'}
objects[key(11)]={'isa':'PBXTargetDependency','target':app,'targetProxy':key(10)}
objects[key(12)]={'isa':'PBXNativeTarget','buildConfigurationList':key(9),'buildPhases':[key(4),key(5),key(6)],'buildRules':[],'dependencies':[key(11)],'name':'WandLiveBackUITests','productName':'WandLiveBackUITests','productReference':key(3),'productType':'com.apple.product-type.bundle.ui-testing'}
objects[main]['targets'].append(key(12))
objects[main]['attributes'].setdefault('TargetAttributes',{})[key(12)]={'CreatedOnToolsVersion':'16.0','TestTargetID':app}
objects[objects[main]['mainGroup']]['children'].append(key(1))
objects[objects[main]['productRefGroup']]['children'].append(key(3))
(project/'project.pbxproj').write_bytes(plistlib.dumps(data))

def ref(parent,target,name,product):
    ET.SubElement(parent,'BuildableReference',{'BuildableIdentifier':'primary','BlueprintIdentifier':target,'BuildableName':product,'BlueprintName':name,'ReferencedContainer':'container:Wand.xcodeproj'})
scheme=ET.Element('Scheme',{'LastUpgradeVersion':'1600','version':'1.3'})
build=ET.SubElement(scheme,'BuildAction',{'parallelizeBuildables':'NO','buildImplicitDependencies':'YES'});entries=ET.SubElement(build,'BuildActionEntries')
for target,name,product in [(app,'Wand','Wand.app'),(key(12),'WandLiveBackUITests','WandLiveBackUITests.xctest')]:
    entry=ET.SubElement(entries,'BuildActionEntry',{'buildForTesting':'YES','buildForRunning':'YES','buildForProfiling':'NO','buildForArchiving':'NO','buildForAnalyzing':'YES'});ref(entry,target,name,product)
test=ET.SubElement(scheme,'TestAction',{'buildConfiguration':'Debug','selectedDebuggerIdentifier':'Xcode.DebuggerFoundation.Debugger.LLDB','selectedLauncherIdentifier':'Xcode.IDEFoundation.Launcher.LLDB','shouldUseLaunchSchemeArgsEnv':'YES'})
testables=ET.SubElement(test,'Testables');entry=ET.SubElement(testables,'TestableReference',{'skipped':'NO','parallelizable':'NO'});ref(entry,key(12),'WandLiveBackUITests','WandLiveBackUITests.xctest')
macro=ET.SubElement(test,'MacroExpansion');ref(macro,app,'Wand','Wand.app')
launch=ET.SubElement(scheme,'LaunchAction',{'buildConfiguration':'Debug','selectedDebuggerIdentifier':'Xcode.DebuggerFoundation.Debugger.LLDB','selectedLauncherIdentifier':'Xcode.IDEFoundation.Launcher.LLDB','launchStyle':'0','useCustomWorkingDirectory':'NO','ignoresPersistentStateOnLaunch':'NO','debugDocumentVersioning':'YES','allowLocationSimulation':'YES'})
runnable=ET.SubElement(launch,'BuildableProductRunnable',{'runnableDebuggingMode':'0'});ref(runnable,app,'Wand','Wand.app')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True);ET.ElementTree(scheme).write(schemes/'LiveBack.xcscheme',encoding='utf-8',xml_declaration=True)
args=['xcrun','xcodebuild','-project',str(project),'-scheme','LiveBack','-configuration','Debug','-derivedDataPath',str(work/'derived'),'-clonedSourcePackagesDirPath','/Volumes/Wand/Developer/ios/tests/SourcePackages','-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO']
build_log=work/'build.log';test_log=work/'test.log'
with build_log.open('w') as log:
    r=subprocess.run(args+['-destination','generic/platform=iOS Simulator','build-for-testing'],stdout=log,stderr=subprocess.STDOUT)
print('build exit='+str(r.returncode)+' log='+str(build_log),flush=True)
if r.returncode:raise SystemExit(r.returncode)
if os.environ.get('BUILD_ONLY')=='1':raise SystemExit(0)
device=os.environ.get('SIMULATOR_ID','3148745E-F2CC-48C7-9BA8-BB54B8E0A891')
filter_name=sys.argv[1] if len(sys.argv)>1 else None
only=['-only-testing:WandLiveBackUITests/LiveBackUITests/'+filter_name] if filter_name else []
run_environment=os.environ.copy()
private_directory=None
if os.environ.get('WAND_ACCEPTANCE_SESSION_ID'):
    private_directory=tempfile.TemporaryDirectory(prefix='wand-native-ui-private-')
    connection=json.loads((pathlib.Path.home()/'.wand/acceptance-connection.json').read_text())
    code=connection['connectionCode'];_,token=base64.b64decode(code+'='*(-len(code)%4)).decode().rsplit('#',1)
    config=json.loads((pathlib.Path.home()/'.wand/config.json').read_text());origin='http://127.0.0.1:'+str(config['port'])
    profile=pathlib.Path(private_directory.name)/'profile.json'
    profile.write_text(json.dumps({'id':'native-ui-acceptance','baseUrl':origin,'token':token,'customName':'本机验收服务'}));profile.chmod(0o600)
    run_environment['TEST_RUNNER_WAND_UI_ACCEPTANCE_PROFILE']=str(profile)
    run_environment['TEST_RUNNER_WAND_UI_ACCEPTANCE_SESSION']=os.environ['WAND_ACCEPTANCE_SESSION_ID']
capture_start=time.time()
stop=threading.Event()
captures=[]
containers=(pathlib.Path.home()/'Library/Developer/CoreSimulator/Devices'/device/'data/Containers/Data/Application').resolve()
# Xcode can replace the app's data-container UUID during installation. Watch the
# known marker under this task-owned simulator, not one stale container path.
def capture_held_frames():
    seen=set()
    while not stop.wait(0.1):
        try:
            proofs=list(containers.glob('*/Documents/live-back-proof/*/*.json'))+list(containers.glob('*/Documents/actual-back-proof/*/*.json'))
            for proof in proofs:
                if proof.name.endswith('.ended.json') or proof.stat().st_mtime<capture_start or str(proof) in seen: continue
                seen.add(str(proof)); record=json.loads(proof.read_text())
                if record.get('mode')=='profile-stage-request':
                    if private_directory is None: continue
                    container=subprocess.run(['xcrun','simctl','get_app_container',device,'com.wand.app','data'],capture_output=True,text=True,timeout=10)
                    if container.returncode:
                        seen.discard(str(proof)); continue
                    destination=pathlib.Path(container.stdout.strip())/'Documents/.wand-acceptance-profile.json'
                    shutil.copyfile(profile,destination);destination.chmod(0o600)
                    proof.with_name('profile-staged.json').write_text('{"ready":true}')
                    continue
                if proof.name=='profile-staged.json': continue
                time.sleep(0.8 if record.get('mode')=='installed' else 0.35)
                output=work/'held-frames'/proof.parent.name
                output.mkdir(parents=True,exist_ok=True)
                image=output/(proof.stem+'.png')
                ended=proof.with_name(proof.stem+'.ended.json')
                was_ended=ended.exists()
                # CoreSimulator's screenshot helper cannot write this external
                # build volume. Stage only the test image on the internal /tmp.
                staging=pathlib.Path('/tmp')/('wand-native-held-'+uuid.uuid4().hex+'.png')
                result=subprocess.run(['xcrun','simctl','io',device,'screenshot','--display=1',str(staging)],capture_output=True,text=True,timeout=15)
                if result.returncode==0:
                    shutil.copyfile(staging,image)
                    staging.unlink()
                record.update({'screenshotExit':result.returncode,'screenshotError':result.stderr[-1000:],'endedBeforeCapture':was_ended,'endedDuringCapture':ended.exists(),'image':str(image)})
                (output/proof.name).write_text(json.dumps(record,indent=2)); captures.append(record)
        except (OSError,ValueError,subprocess.TimeoutExpired): continue
thread=threading.Thread(target=capture_held_frames,daemon=True);thread.start()
try:
    with test_log.open('w') as log:
        r=subprocess.run(args+['-destination','platform=iOS Simulator,id='+device]+only+['test-without-building'],env=run_environment,stdout=log,stderr=subprocess.STDOUT,timeout=600)
finally:
    stop.set();thread.join(timeout=20)
    if private_directory is not None: private_directory.cleanup()
(work/'held-frame-captures.json').write_text(json.dumps(captures,indent=2))
after=source_hashes()
(work/'verification.json').write_text(json.dumps({'testExit':r.returncode,'sourcesUnchanged':before==after,'sources':before,'snapshot':str(work/'verified-sources'/snapshot_id),'captures':len(captures)},indent=2))
print('test exit='+str(r.returncode)+' log='+str(test_log)+' captured='+str(len(captures))+' stable='+str(before==after),flush=True)
raise SystemExit(r.returncode if before==after else 1)
