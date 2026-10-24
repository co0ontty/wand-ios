#!/usr/bin/env python3
"""Focused native-navigation unit + explicit own-session installed-service check."""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

root=pathlib.Path(__file__).resolve().parents[1]
work=pathlib.Path(os.environ.get('LIVE_BACK_UNIT_ROOT','/Volumes/Wand/Developer/ios/live-native-back/unit'))
work.mkdir(parents=True,exist_ok=True)
sources=['Wand/NativeRootView.swift','Wand/SessionDestinationView.swift','Wand/ChatView.swift','Wand/ConversationViews.swift','Wand/NewConversationView.swift','Wand/ContactsView.swift','Wand/Theme.swift','WandTests/HomeParityTests.swift','WandTests/CurrentAndroidParityTests.swift']
def hashes():return {p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sources}
before=hashes();env=os.environ.copy();env.update({'BUILD_ONLY':'1','DERIVED_DATA':str(work/'derived')})
with (work/'build.log').open('w') as log:
 r=subprocess.run(['./scripts/run-tests.sh'],cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
print('unit build exit='+str(r.returncode),flush=True)
if r.returncode:raise SystemExit(r.returncode)
filters=['HomeParityTests/testSystemNavigationKeepsTheSameRealListAndParentControllers','HomeParityTests/testHiddenBarBridgeUsesAndRestoresTheExistingUIKitGesture','HomeParityTests/testSystemNavigationRetainsLiveStackAcrossFourSizes','CurrentAndroidParityTests/testConversationPreviewsShareMarkdownAndDestinationsOwnNavigationChrome']
session=os.environ.get('WAND_ACCEPTANCE_SESSION_ID')
if session:filters.append('HomeParityTests/testInstalledRootNavigationHidesOnlyWhileDetailsAreOpen')
args=['xcrun','xcodebuild','-project',str(root/'Wand.xcodeproj'),'-scheme','Wand','-configuration','Debug','-derivedDataPath',str(work/'derived'),'-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','-destination','platform=iOS Simulator,id='+os.environ.get('SIMULATOR_ID','43A9B9F3-B0E2-48F7-8ECE-B04A1222E9CA')]
args+=['-only-testing:WandTests/'+f for f in filters]+['test-without-building']
with tempfile.TemporaryDirectory(prefix='wand-native-private-') as directory:
 run_env=os.environ.copy()
 if session:
  connection=json.loads((pathlib.Path.home()/'.wand/acceptance-connection.json').read_text())
  code=connection['connectionCode'];_,token=base64.b64decode(code+'='*(-len(code)%4)).decode().rsplit('#',1)
  config=json.loads((pathlib.Path.home()/'.wand/config.json').read_text());origin='http://127.0.0.1:'+str(config['port'])
  profile=pathlib.Path(directory)/'connection.json';profile.write_text(json.dumps({'serverURL':origin,'connectionCode':base64.b64encode((origin+'#'+token).encode()).decode()}));profile.chmod(0o600)
  run_env['TEST_RUNNER_WAND_TEST_ROOT_ACCEPTANCE_PATH']=str(profile)
  run_env['TEST_RUNNER_WAND_TEST_ROOT_ACCEPTANCE_SESSION']=session
 with (work/'test.log').open('w') as log:
  r=subprocess.run(args,cwd=root,env=run_env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
after=hashes();receipt={'exitCode':r.returncode,'sourcesUnchanged':before==after,'sources':before,'filters':filters,'globalPrivatePointersWritten':False}
(work/'verification.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'exitCode':r.returncode,'sourcesUnchanged':before==after}),flush=True)
raise SystemExit(r.returncode if before==after else 1)
