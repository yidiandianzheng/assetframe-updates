# AssetFrame 在线服务

这个 Worker 同时提供 Sparkle 更新文件、反馈接收、D1 留底、R2 临时截图和飞书多维表格转发。客户端不会持有飞书密钥。

## 首次配置

1. 安装 Node.js 20 以上版本，执行 `npm install`。
2. 登录 Cloudflare：`npx wrangler login`。
3. 创建 D1：`npx wrangler d1 create assetframe-feedback`。
4. 创建两个 R2 Bucket：`assetframe-updates`、`assetframe-feedback`。
5. 已有一个飞书多维表格 Base 时，可执行 `./setup-feishu-base.sh <base_token>` 自动创建固定字段和五个视图；脚本会输出 app token 与 table ID。也可按下文手动创建。
6. 复制 `wrangler.example.toml` 为 `wrangler.toml`，填写 D1 ID、飞书多维表格的 app token 和 table ID。
7. 分别执行 `npx wrangler secret put FEISHU_APP_ID`、`FEISHU_APP_SECRET`、`RATE_LIMIT_HMAC_SECRET`。最后一个值应使用随机长字符串。
8. 执行 `npm run db:migrate:remote`、`npm test`、`npm run deploy`。

## 飞书多维表格

自建应用需要云文档/多维表格记录写入和素材上传权限。表格字段必须与 Worker 中的名称一致：

- 反馈编号、提交时间、反馈类型、反馈内容
- 状态、优先级、目标版本、处理结论
- 应用版本、macOS版本、芯片、所在界面
- 截图、联系方式、匿名安装标识

其中“截图”为附件字段，“提交时间”为日期字段；“反馈类型、状态、优先级”建议使用单选字段。建立“新反馈、按版本汇总、处理中、待发布验证、已关闭”五个视图。未提供飞书凭据时，Worker 仍会将反馈保存在 D1 和 R2，定时任务会在配置完成后继续转发。

## 路由与数据边界

- `GET /appcast.xml`：稳定更新源，不缓存。
- `GET /releases/*`：不可变版本文件，长期缓存。
- `POST /v1/feedback`：`multipart/form-data`，`payload` 为 JSON，`screenshot` 可选。
- 正文最多 5000 字；截图最多 5MB，仅 PNG/JPEG；安装标识和 IP 各自每小时最多 10 次。
- IP 只用于带密钥 HMAC 限流，不以明文写入 D1。截图成功写入飞书后从 R2 删除；飞书失败时由 5 分钟定时任务重试。
