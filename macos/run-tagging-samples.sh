#!/bin/zsh
# Real source files and production SQLite are read-only; every analysis input is a QA copy.
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
QA_ROOT="${ASSETFRAME_TAGGING_SAMPLE_ROOT:-$(mktemp -d /tmp/assetframe-qa.tagging-samples.XXXXXX)}"
[[ "$QA_ROOT" == /tmp/assetframe-qa.tagging-samples.* ]] || { print -u2 'QA root must use /tmp/assetframe-qa.tagging-samples.*'; exit 1; }
REPORT_DIR="$SCRIPT_DIR/ProductValidation/20261023_标签整理候选/samples"
mkdir -p "$QA_ROOT" "$REPORT_DIR"
export ASSETFRAME_QA_DATA_ROOT="$QA_ROOT/runtime"
export TAGGING_SAMPLE_ROOT="$QA_ROOT" TAGGING_SAMPLE_REPORT="$REPORT_DIR" TAGGING_PROJECT_DIR="$SCRIPT_DIR"
python3 - <<'PY'
import os,sqlite3,json,csv,re,urllib.parse,hashlib,shutil,random,time,collections
from pathlib import Path
qa=Path(os.environ['TAGGING_SAMPLE_ROOT']); reports=Path(os.environ['TAGGING_SAMPLE_REPORT']); project=Path(os.environ['TAGGING_PROJECT_DIR'])
manifest=qa/'manifest.json'
if manifest.exists():
 print('Reusing existing QA manifest:',manifest);raise SystemExit
inputs={'tea':'/Volumes/SSD-1TB/Ai资产管理/香万家木兰.assetframelibrary/global-material-library.sqlite','drama':'/Volumes/SSD-1TB/Ai资产管理/古代种田/新资源库.assetframelibrary/global-material-library.sqlite'}
allrecords=[];bys={};snapshots=[]
for domain,path in inputs.items():
 connection=sqlite3.connect('file:'+urllib.parse.quote(path)+'?mode=ro',uri=True)
 target=qa/(domain+'-index-copy.sqlite');dest=sqlite3.connect(target);connection.backup(dest);dest.close()
 records=[json.loads(x[0]) for x in connection.execute('SELECT payload FROM materials')];connection.close()
 allrecords+=records
 images={os.path.realpath(r['sourcePath']):r for r in records if r.get('kind')=='图片' and not r.get('deletedAt') and os.path.isfile(r.get('sourcePath') or '')}
 bys[domain]=images;snapshots.append({'domain':domain,'recordCount':len(records),'availableImages':len(images),'snapshot':str(target),'sqliteReadMode':'mode=ro + backup to QA'})
(qa/'full-index-records.json').write_text(json.dumps(allrecords,ensure_ascii=False))
refs={'tea':{},'drama':{}};pattern=re.compile(r'!?\[[^\]]*\]\(<?([^>\n]+?)>?\)')
for row in csv.DictReader(open(project/'Documentation/资产分类词表/数据来源清单.csv',encoding='utf-8-sig')):
 domain=row['域'];doc=row['来源路径']
 if domain not in refs or any(x in doc for x in ['历史','归档','停用','备份']):continue
 try:text=Path(doc).read_text()
 except (OSError,UnicodeError):continue
 if len(text.encode())>256*1024:continue
 matches=list(pattern.finditer(text));local=[]
 for match in matches:
  raw=urllib.parse.unquote(match.group(1).split('#')[0])
  if '://' in raw:continue
  resolved=os.path.realpath(raw if raw.startswith('/') else os.path.join(os.path.dirname(doc),raw))
  if resolved in bys[domain]:local.append(resolved)
 for path in local:
  refs[domain].setdefault(path,[]).append((len(set(local)),doc,text))
samples=[];derived=[];sources=[];counter=0
for domain,images in bys.items():
 randomizer=random.Random(20261023)
 mapped=sorted(refs[domain],key=lambda p:(min(x[0] for x in refs[domain][p]),p))
 mapped=mapped[:(35 if domain=='drama' else 50)]
 other=sorted(set(images)-set(refs[domain]));randomizer.shuffle(other)
 selected=mapped+other[:50-len(mapped)]
 assert len(selected)==50
 copied={}
 for path in selected:
  counter+=1;record=dict(images[path]);suffix=Path(path).suffix.lower();image=qa/'images'/domain/(f'{counter:03d}'+suffix)
  image.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,image)
  originalhash=hashlib.sha256(Path(path).read_bytes()).hexdigest();copyhash=hashlib.sha256(image.read_bytes()).hexdigest();assert originalhash==copyhash
  copied[path]=str(image)
  record.update(sourcePath=str(image),sourceLocations=[str(image)],fingerprint=copyhash,contentFingerprint=copyhash)
  samples.append({'ordinal':counter,'domain':domain,'originalPath':path,'imageSHA256':copyhash,'record':record,'originalDocument':None,'fixtureDocument':None,'fixtureDerivation':'未找到明确原始引用；没有构造文档关联'})
 docs=qa/'documents'/domain;docs.mkdir(parents=True,exist_ok=True)
 sources.append({'id':domain,'name':'茶商业样例' if domain=='tea' else '古装短剧样例','path':str(docs),'scope':'茶商业' if domain=='tea' else '古装短剧'})
 used={}
 for sample in [s for s in samples if s['domain']==domain]:
  choices=refs[domain].get(sample['originalPath'])
  if not choices:continue
  _,doc,text=min(choices,key=lambda item:(item[0],len(item[2]),item[1]))
  if doc not in used:
   def rewrite(match):
    raw=urllib.parse.unquote(match.group(1).split('#')[0])
    if '://' in raw:return match.group(0)
    absolute=os.path.realpath(raw if raw.startswith('/') else os.path.join(os.path.dirname(doc),raw))
    replacement=copied.get(absolute,absolute)
    return match.group(0).replace(match.group(1),replacement)
   transformed=pattern.sub(rewrite,text)
   out=docs/(f'{len(used)+1:03d}_'+Path(doc).name)
   out.write_text(transformed);used[doc]=str(out)
   derived.append({'originalDocument':doc,'originalSHA256':hashlib.sha256(Path(doc).read_bytes()).hexdigest(),'fixtureDocument':str(out),'fixtureSHA256':hashlib.sha256(out.read_bytes()).hexdigest(),'method':'整篇真实文档复制；已有本地Markdown链接解析为绝对路径，所选图片引用改指QA副本；其余文本不变。未新增原文不存在的关联，未宣称原始引用等于生成原文。'})
  sample.update(originalDocument=doc,fixtureDocument=used[doc],fixtureDerivation='由真实明确Markdown图片引用派生QA文档；能否提取对应片段仍由正式Analyzer判断')
result={'qaRoot':str(qa),'createdAt':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'productionReadOnly':True,'networkCalls':0,'snapshots':snapshots,'sources':sources,'samples':samples,'derivedDocuments':derived}
manifest.write_text(json.dumps(result,ensure_ascii=False,indent=2));shutil.copy2(manifest,reports/'sample-manifest.json')
print('Prepared 100 verified image copies:',qa,'mapped:',dict(collections.Counter(s['domain'] for s in samples if s['originalDocument'])))
PY
mkdir -p "$QA_ROOT/sources"
python3 - <<'PY'
import os,re,hashlib,json,shutil
from pathlib import Path
project=Path(os.environ['TAGGING_PROJECT_DIR']);qa=Path(os.environ['TAGGING_SAMPLE_ROOT'])
script=(project/'run-tagging-tests.sh').read_text();names=re.search(r'for name in (.+?); do',script).group(1).split()
if 'MaterialTaggingLocalVision' not in names:names.append('MaterialTaggingLocalVision')
files=[project/'Sources/AssetFrame'/(n+'.swift') for n in names]+[project/'SelfTests/MaterialTaggingRealSampleTest.swift',project/'run-tagging-samples.sh']
digests={str(p.relative_to(project)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
stamp=hashlib.sha256(json.dumps(digests,sort_keys=True).encode()).hexdigest();old=qa/'source-hashes.json'
reuse=(qa/'sample-test').exists() and old.exists() and json.loads(old.read_text()).get('aggregateSHA256')==stamp
if not reuse:
 checkpoint=qa/'sample-results.json'
 if checkpoint.exists():checkpoint.rename(qa/('sample-results.previous-'+str(int(__import__('time').time()))+'.json'))
 for p in files:shutil.copy2(p,qa/'sources'/p.name)
 old.write_text(json.dumps({'aggregateSHA256':stamp,'sources':digests},ensure_ascii=False,indent=2))
(qa/'needs-build').write_text('no' if reuse else 'yes')
shutil.copy2(old,Path(os.environ['TAGGING_SAMPLE_REPORT'])/'source-hashes.json')
PY
if [[ "$(cat "$QA_ROOT/needs-build")" == yes ]]; then
    swiftc -O -swift-version 6 -parse-as-library "$QA_ROOT"/sources/*.swift -o "$QA_ROOT/sample-test"
fi
"$QA_ROOT/sample-test" "$QA_ROOT" "$REPORT_DIR"
print "QA_ROOT=$QA_ROOT"
print "REPORT_DIR=$REPORT_DIR"
