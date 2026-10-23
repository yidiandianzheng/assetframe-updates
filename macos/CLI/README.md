# 向量AI资产管家 CLI

先打开桌面应用，再用CLI查询和操作。协议1使用本机 `127.0.0.1` 动态端口，服务与桌面应用共用当前资源库与播放器，没有独立数据库写入进程。

## 安装与常用命令

已打包应用内含 `Contents/Resources/assetframe-cli`（Python标准库客户端）。本机安装后入口为 `~/.local/bin/assetframe`，也可直接执行完整路径。使用系统 `/usr/bin/python3`；需要macOS Command Line Tools提供Python 3。不自动修改shell配置。

```sh
~/.local/bin/assetframe status
~/.local/bin/assetframe capabilities --json
~/.local/bin/assetframe libraries
~/.local/bin/assetframe list --kind 视频 --limit 20 --json
~/.local/bin/assetframe list --query 木兰 --offset 0 --limit 50
~/.local/bin/assetframe show '<素材ID>'
~/.local/bin/assetframe search '木兰'
~/.local/bin/assetframe focus '<素材ID>'
~/.local/bin/assetframe preview '<素材ID>'
~/.local/bin/assetframe playback status
~/.local/bin/assetframe playback play
~/.local/bin/assetframe playback pause
~/.local/bin/assetframe playback seek 3.0
~/.local/bin/assetframe exit-preview
~/.local/bin/assetframe diagnostics --output /tmp/assetframe-diagnostics.json
```

`list`查询当前库全部记录，不受界面目录、搜索、过滤影响；默认排除回收站，支持 `--include-deleted`。分页按照素材ID稳定排序，limit范围1–200；跨页时库若被用户修改，需重新查询。

`search`沿用当前界面目录和筛选，空字符串清空搜索。`focus`、`preview`只接受当前可见结果内的ID；请先调整桌面端的范围/筛选，等待 `status.result.workspace.queryPending` 为false。预览会沿用桌面端的最近使用记录规则。`focus`只选择，不关闭已有大预览；`exit-preview`返回画册并暂停当前媒体。

导航返回 `accepted`表示操作已提交，界面绘制或媒体分析可能尚未完成。用status核对focusedID和workspace.preview；播放前等待 `playback status` 的ready为true。play和pause幂等；seek必须在媒体时长内。详情有未保存草稿时，导航返回unsaved_edits，先在桌面端解决草稿。

`diagnostics`汇总版本、系统、库路径、记录数、导入/持久化状态、查询与使用时间版本、当前界面和播放器状态；不执行扫描或数据库修复。报告包含本机路径和搜索条件，输出不含连接token，另存文件0600且不覆盖已有文件。

## 协议与隔离调试

生产连接信息在 `~/Library/Application Support/AssetFrame/CLI/endpoint.json`；CLI目录0700，endpoint文件0600。端口和token在每次启动时重新生成，正常退出删除本实例endpoint。异常退出后的文件可能保留；重启同一数据根会取得运行锁并替换文件。客户端遇到失联时返回连接错误，不自动启动软件。

```sh
./CLI/assetframe status --endpoint /tmp/assetframe-qa.cli6/CLI/endpoint.json --json
```

隔离应用继续遵守ASSETFRAME_QA_DATA_ROOT限制，使用独立endpoint和原有隔离库。生产和QA可以同时运行，同一数据根只允许一个CLI服务。客户端只连接127.0.0.1，拒绝symlink、非当前用户、组/其他用户可读的endpoint文件。

TCP请求为一个UTF-8 JSON对象加换行，每个连接一条请求：

```json
{"protocolVersion":1,"id":"unique-request-id","token":"从私有endpoint读取","command":"materials.list","arguments":{"query":"木兰","limit":"20","offset":"0"}}
```

响应含protocolVersion、id、ok，以及result或error(code/message)。调用 `capabilities`获得实际可用命令和参数。参数值均为字符串；未知命令、未知参数和无效数值会报错。请求上限64KB，每个实例最多8个连接，服务端5秒截止，客户端默认8秒；响应客户端上限8MB。

CLI退出码：0成功，2命令用法错误，3应用拒绝操作，4连接/客户端错误。每条命令支持 `--json`、`--endpoint`、`--timeout`，选项放在完整子命令之后（例如 `playback status --json`）。

第一版操作范围是查询、界面导航和播放；素材编辑、导入、导出、删除、切库、清缓存不在本版命令集合内。连接凭据允许同一本机用户控制当前应用，不写入普通诊断报告，也不要公开分享endpoint文件。

## 开发验证

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./run-self-tests.sh --cli-only
python3 SelfTests/CLIClientSelfTest.py
```

CLI目标是本实例最后挂载的素材工作区，第一版不提供多窗口ID定向；status会返回当前工作区状态。一次查询返回当前内存快照，需以busy/loading/queryPending检查准备状态。

V261012.7的 `status` 与 `diagnostics` 在 `result.workspace.searchIndex` 返回active、cacheHit、buildCount、cachedRecordCount、estimatedBytes、buildMilliseconds和fallbackReason。buildCount按已完成的构建/回退尝试统计；estimatedBytes是文本和字典开销估算，不代表进程峰值。缓存属于当前挂载的库浏览器，切库后重置；空搜索不构建，超2万条或约24MB估算预算时回退原查询。
# V261012.8 新增操作

```sh
assetframe cache-status
assetframe release-preview-memory
assetframe pause-import
assetframe resume-import
assetframe undo
assetframe redo
assetframe libraries
assetframe open-library <已登记资源库ID>
```

暂停等待当前批次收尾后返回；恢复返回任务已开始，可用status观察进度。撤销/重做等待数据库提交成功后返回committed；发生字段冲突整批拒绝。切库仅接受已登记ID，详情有未保存修改时拒绝。cache-status在后台有界统计，truncated为true时是部分结果；不会清理磁盘文件。status增加导入、整理历史和切库用时。



### 隔离库固定操作测量

`assetframe measure --scenario /完整路径/scenario.json --output /完整路径/report.json --repeat 3 --endpoint /tmp/assetframe-qa.测试/CLI/endpoint.json --json`

仅允许隔离根目录内资源库。先验证整份场景，再执行status、search、focus、preview、exit-preview、seek；不支持导入、编辑、切库或删除。场景为JSON：`{"name":"翻图","steps":[{"command":"search","query":""},{"command":"preview","id":"素材ID","waitForMedia":true},{"command":"seek","seconds":2.5},{"command":"exit-preview"}]}`。图片预览省略waitForMedia。

报告记录请求耗时、等待查询/媒体/解码队列就绪耗时、版本、素材数量、RSS和索引诊断。回放中进程或库改变、超时、操作拒绝即失败；不覆盖已有报告，文件权限0600。计时不代表实际像素首显或FPS，也不包含手动滑杆拖动。status新增cacheBudget和定位中的状态/计数。
