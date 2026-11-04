#!/usr/bin/env python3
"""复用现有本地自测依赖清单，不运行整套脚本或任何线上模型。"""
from pathlib import Path
import re, subprocess, os, sys
root=Path(__file__).resolve().parent
qa=Path('/tmp/assetframe-qa.pcat-20261026-01')
script=(root/'run-self-tests.sh').read_text()
def sources(name):
    body=re.search(r'^'+name+r'=\((.*?)^\)',script,re.M|re.S).group(1)
    result=[]
    for file, nested in re.findall(r'\$SOURCE_SNAPSHOT/([^"\s]+)|\$\{([A-Z_]+)\[@\]\}',body):
        if file: result.append(root/'Sources/AssetFrame'/file)
        else: result+=sources(nested)
    return result
files=sources('COMMON_SOURCES')
for name in ['ProjectClassificationProfile.swift','ProjectClassificationParser.swift','GalleryAutoClassifier.swift','MaterialDatabase.swift','MaterialImportController.swift','GlobalMaterialStore.swift']:
    p=root/'Sources/AssetFrame'/name
    if p not in files: files.append(p)
sdk='/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
env=dict(os.environ,ASSETFRAME_QA_DATA_ROOT=str(qa))
# One compilation for persistence and existing classification/filter regressions.
combined=qa/'combined-regressions'
combined.mkdir(exist_ok=True)
regressions=[]
for name in ['MaterialClassificationSelfTest','MaterialFilterSelfTest']:
    text=(root/'SelfTests'/(name+'.swift')).read_text().replace('@main ', '')
    text=text.replace('assetframe-classification-', 'assetframe-qa.classification-')
    path=combined/(name+'.swift'); path.write_text(text); regressions.append(path)
entry=(root/'SelfTests/ProjectClassificationPersistenceSelfTest.swift').read_text().replace('import Foundation', 'import Foundation\nimport Darwin', 1).replace('@MainActor static func main() async throws {', '@MainActor static func main() async throws {\n        setbuf(stdout, nil)', 1)
entry=entry.replace('        print("ProjectClassificationPersistenceSelfTest passed")', '        print("ProjectClassificationPersistenceSelfTest passed")\n        if CommandLine.arguments.contains("--legacy-classification") { try await MaterialClassificationSelfTest.main() }\n        try MaterialFilterSelfTest.main()')
entryPath=combined/'ProjectClassificationCombinedSelfTest.swift';entryPath.write_text(entry)
target=qa/'ProjectClassificationCombinedSelfTest'
subprocess.run(['swiftc','-swift-version','6','-D','ASSETFRAME_SELF_TEST','-parse-as-library','-sdk',sdk,*map(str,files),*map(str,regressions),str(entryPath),'-o',str(target)],check=True,env=env)
subprocess.run([str(target), *sys.argv[1:]],check=True,env=env)
