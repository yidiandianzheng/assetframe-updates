const MAX_MESSAGE_LENGTH = 5_000;
const MAX_CONTACT_LENGTH = 200;
const MAX_SCREENSHOT_BYTES = 5 * 1024 * 1024;
const MAX_SUBMISSIONS_PER_HOUR = 10;
const SCREENSHOT_TYPES = new Set(["image/jpeg", "image/png"]);
const FEISHU_ROOT = "https://open.feishu.cn/open-apis";

let cachedTenantToken = null;

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/health") {
        return json({ ok: true, service: "assetframe-online" });
      }
      if (["GET", "HEAD"].includes(request.method) && url.pathname === "/appcast.xml") {
        return serveR2Object(env.UPDATES_R2, "feeds/stable/appcast.xml", false, request);
      }
      if (["GET", "HEAD"].includes(request.method) && url.pathname.startsWith("/releases/")) {
        return serveR2Object(env.UPDATES_R2, url.pathname.slice(1), true, request);
      }
      if (request.method === "POST" && url.pathname === "/v1/feedback") {
        return acceptFeedback(request, env, ctx);
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      console.error("request_failed", safeError(error));
      return json({ error: "internal_error" }, 500);
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(deliverPendingFeedback(env));
    ctx.waitUntil(env.DB.prepare("DELETE FROM rate_events WHERE created_at < ?")
      .bind(new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()).run());
  },
};

export async function acceptFeedback(request, env, ctx) {
  const contentType = request.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("multipart/form-data")) {
    return json({ error: "multipart_required" }, 415);
  }

  let form;
  try {
    form = await request.formData();
  } catch {
    return json({ error: "invalid_multipart" }, 400);
  }

  const rawPayload = form.get("payload");
  if (typeof rawPayload !== "string") return json({ error: "payload_required" }, 400);

  let payload;
  try {
    payload = JSON.parse(rawPayload);
  } catch {
    return json({ error: "invalid_payload_json" }, 400);
  }
  const validationError = validateFeedbackPayload(payload);
  if (validationError) return json({ error: validationError }, 400);

  const screenshot = form.get("screenshot");
  if (screenshot != null && typeof screenshot !== "string") {
    if (!SCREENSHOT_TYPES.has(screenshot.type)) return json({ error: "unsupported_screenshot_type" }, 415);
    if (screenshot.size > MAX_SCREENSHOT_BYTES) return json({ error: "screenshot_too_large" }, 413);
  }

  const existing = await env.DB.prepare("SELECT submission_id, received_at FROM feedback WHERE submission_id = ?")
    .bind(payload.submissionId).first();
  if (existing) {
    return json({ submissionId: existing.submission_id, receivedAt: existing.received_at }, 202);
  }

  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const rateKeys = await Promise.all([
    hmacHex(env.RATE_LIMIT_HMAC_SECRET, `install:${payload.anonymousInstallIdHash}`),
    hmacHex(env.RATE_LIMIT_HMAC_SECRET, `ip:${ip}`),
  ]);
  if (!(await consumeRateLimit(env.DB, rateKeys))) {
    return json({ error: "rate_limited" }, 429, { "Retry-After": "3600" });
  }

  const receivedAt = new Date().toISOString();
  let screenshotKey = null;
  let screenshotContentType = null;
  if (screenshot != null && typeof screenshot !== "string") {
    screenshotContentType = screenshot.type;
    const extension = screenshot.type === "image/png" ? "png" : "jpg";
    screenshotKey = `feedback/${payload.submissionId}.${extension}`;
    await env.FEEDBACK_R2.put(screenshotKey, await screenshot.arrayBuffer(), {
      httpMetadata: { contentType: screenshot.type, cacheControl: "private, no-store" },
    });
  }

  try {
    await env.DB.batch([
      env.DB.prepare(`INSERT OR IGNORE INTO feedback (
          submission_id, received_at, feedback_type, message, app_short_version, build_version,
          macos_version, architecture, screen_id, region_json, anonymous_install_id_hash,
          contact, diagnostics_included, screenshot_key, screenshot_content_type, payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .bind(
          payload.submissionId, receivedAt, payload.type, payload.message.trim(), payload.appShortVersion,
          payload.buildVersion, payload.macOSVersion || null, payload.architecture || null, payload.screenId,
          JSON.stringify(payload.region), payload.anonymousInstallIdHash, optionalText(payload.contact),
          payload.diagnosticsIncluded ? 1 : 0, screenshotKey, screenshotContentType, JSON.stringify(payload),
        ),
      env.DB.prepare(`INSERT OR IGNORE INTO feedback_outbox
        (submission_id, attempts, next_attempt_at, created_at) VALUES (?, 0, ?, ?)`)
        .bind(payload.submissionId, receivedAt, receivedAt),
    ]);
  } catch (error) {
    if (screenshotKey) await env.FEEDBACK_R2.delete(screenshotKey);
    throw error;
  }

  ctx.waitUntil(deliverPendingFeedback(env));
  return json({ submissionId: payload.submissionId, receivedAt }, 202);
}

export function validateFeedbackPayload(payload) {
  if (!payload || payload.schemaVersion !== 1) return "unsupported_schema";
  if (!isUUID(payload.submissionId)) return "invalid_submission_id";
  if (!["故障", "体验优化", "功能建议", "其他"].includes(payload.type)) return "invalid_type";
  if (typeof payload.message !== "string" || !payload.message.trim()) return "message_required";
  if (payload.message.trim().length > MAX_MESSAGE_LENGTH) return "message_too_long";
  if (payload.contact != null && (typeof payload.contact !== "string" || payload.contact.length > MAX_CONTACT_LENGTH)) return "contact_too_long";
  if (typeof payload.appShortVersion !== "string" || typeof payload.buildVersion !== "string") return "version_required";
  if (typeof payload.screenId !== "string" || !payload.screenId || payload.screenId.length > 200) return "invalid_screen_id";
  if (!validRegion(payload.region)) return "invalid_region";
  if (typeof payload.anonymousInstallIdHash !== "string" || !/^[a-f0-9]{64}$/i.test(payload.anonymousInstallIdHash)) return "invalid_install_id";
  if (typeof payload.diagnosticsIncluded !== "boolean") return "diagnostics_consent_required";
  return null;
}

export async function deliverPendingFeedback(env) {
  if (!env.FEISHU_APP_ID || !env.FEISHU_APP_SECRET || !env.FEISHU_APP_TOKEN || !env.FEISHU_TABLE_ID) return;
  const due = await env.DB.prepare(`SELECT f.* , o.attempts
      FROM feedback_outbox o JOIN feedback f ON f.submission_id = o.submission_id
      WHERE o.next_attempt_at <= ? ORDER BY o.created_at LIMIT 20`)
    .bind(new Date().toISOString()).all();

  for (const row of due.results || []) {
    try {
      const token = await tenantAccessToken(env);
      let fileToken = null;
      if (row.screenshot_key) {
        const object = await env.FEEDBACK_R2.get(row.screenshot_key);
        if (object?.body) {
          fileToken = await uploadFeishuScreenshot(env, token, row, object);
        }
      }
      const recordID = await createFeishuRecord(env, token, row, fileToken);
      const deliveredAt = new Date().toISOString();
      await env.DB.batch([
        env.DB.prepare("UPDATE feedback SET feishu_record_id = ?, delivered_at = ? WHERE submission_id = ?")
          .bind(recordID, deliveredAt, row.submission_id),
        env.DB.prepare("DELETE FROM feedback_outbox WHERE submission_id = ?").bind(row.submission_id),
      ]);
      if (row.screenshot_key) await env.FEEDBACK_R2.delete(row.screenshot_key);
    } catch (error) {
      const attempts = Number(row.attempts || 0) + 1;
      const delaySeconds = Math.min(6 * 60 * 60, 60 * (2 ** Math.min(attempts - 1, 8)));
      await env.DB.prepare(`UPDATE feedback_outbox
          SET attempts = ?, next_attempt_at = ?, last_error = ? WHERE submission_id = ?`)
        .bind(attempts, new Date(Date.now() + delaySeconds * 1000).toISOString(), safeError(error), row.submission_id)
        .run();
    }
  }
}

async function serveR2Object(bucket, key, immutable, request) {
  if (request.method === "HEAD") {
    const object = await bucket.head(key);
    if (!object) return json({ error: "not_found" }, 404);
    const headers = objectHeaders(object, immutable);
    headers.set("Content-Length", String(object.size));
    return new Response(null, { headers });
  }

  const object = await bucket.get(key, { range: request.headers });
  if (!object?.body) return json({ error: "not_found" }, 404);
  const headers = objectHeaders(object, immutable);
  let status = 200;
  if (object.range) {
    const start = object.range.offset;
    const end = start + object.range.length - 1;
    headers.set("Content-Range", `bytes ${start}-${end}/${object.size}`);
    headers.set("Content-Length", String(object.range.length));
    status = 206;
  }
  return new Response(object.body, { status, headers });
}

function objectHeaders(object, immutable) {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Accept-Ranges", "bytes");
  headers.set("Cache-Control", immutable ? "public, max-age=31536000, immutable" : "no-cache, no-store, must-revalidate");
  return headers;
}

async function consumeRateLimit(db, rateKeys) {
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  for (const key of rateKeys) {
    const row = await db.prepare("SELECT COUNT(*) AS count FROM rate_events WHERE rate_key = ? AND created_at >= ?")
      .bind(key, since).first();
    if (Number(row?.count || 0) >= MAX_SUBMISSIONS_PER_HOUR) return false;
  }
  const now = new Date().toISOString();
  await db.batch(rateKeys.map((key) => db.prepare("INSERT INTO rate_events (rate_key, created_at) VALUES (?, ?)").bind(key, now)));
  return true;
}

async function tenantAccessToken(env) {
  if (cachedTenantToken?.expiresAt > Date.now() + 60_000) return cachedTenantToken.value;
  const response = await fetch(`${FEISHU_ROOT}/auth/v3/tenant_access_token/internal`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ app_id: env.FEISHU_APP_ID, app_secret: env.FEISHU_APP_SECRET }),
  });
  const result = await response.json();
  if (!response.ok || result.code !== 0 || !result.tenant_access_token) throw new Error(`feishu_auth_${result.code || response.status}`);
  cachedTenantToken = { value: result.tenant_access_token, expiresAt: Date.now() + Number(result.expire || 7_200) * 1000 };
  return cachedTenantToken.value;
}

async function uploadFeishuScreenshot(env, token, row, object) {
  const bytes = await object.arrayBuffer();
  const extension = row.screenshot_content_type === "image/png" ? "png" : "jpg";
  const form = new FormData();
  form.set("file_name", `${row.submission_id}.${extension}`);
  form.set("parent_type", "bitable_image");
  form.set("parent_node", env.FEISHU_APP_TOKEN);
  form.set("size", String(bytes.byteLength));
  form.set("file", new Blob([bytes], { type: row.screenshot_content_type }), `${row.submission_id}.${extension}`);
  const response = await fetch(`${FEISHU_ROOT}/drive/v1/medias/upload_all`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
  const result = await response.json();
  if (!response.ok || result.code !== 0 || !result.data?.file_token) throw new Error(`feishu_media_${result.code || response.status}`);
  return result.data.file_token;
}

async function createFeishuRecord(env, token, row, fileToken) {
  const fields = {
    "反馈编号": row.submission_id,
    "提交时间": Date.parse(row.received_at),
    "反馈类型": row.feedback_type,
    "反馈内容": row.message,
    "状态": "新反馈",
    "优先级": "待评估",
    "应用版本": `${row.app_short_version} (${row.build_version})`,
    "macOS版本": row.macos_version || "未授权",
    "芯片": row.architecture || "未授权",
    "所在界面": row.screen_id,
    "联系方式": row.contact || "",
    "匿名安装标识": row.anonymous_install_id_hash,
  };
  if (fileToken) fields["截图"] = [{ file_token: fileToken }];
  const response = await fetch(
    `${FEISHU_ROOT}/bitable/v1/apps/${encodeURIComponent(env.FEISHU_APP_TOKEN)}/tables/${encodeURIComponent(env.FEISHU_TABLE_ID)}/records`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ fields }),
    },
  );
  const result = await response.json();
  if (!response.ok || result.code !== 0 || !result.data?.record?.record_id) throw new Error(`feishu_record_${result.code || response.status}`);
  return result.data.record.record_id;
}

async function hmacHex(secret, value) {
  if (!secret) throw new Error("missing_rate_limit_secret");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function validRegion(region) {
  if (!region || typeof region !== "object") return false;
  return ["x", "y", "width", "height"].every((key) => Number.isFinite(region[key]))
    && region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0
    && region.x <= 1 && region.y <= 1 && region.width <= 1 && region.height <= 1;
}

function isUUID(value) {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function optionalText(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

function safeError(error) {
  return String(error?.message || error || "unknown_error").slice(0, 500);
}

function json(value, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...extraHeaders },
  });
}
