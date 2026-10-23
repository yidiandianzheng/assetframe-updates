import assert from "node:assert/strict";
import test from "node:test";
import worker, { validateFeedbackPayload } from "../src/worker.mjs";

function validPayload() {
  return {
    schemaVersion: 1,
    submissionId: "01234567-89ab-4cde-8f01-23456789abcd",
    type: "体验优化",
    message: "右侧面板需要完整显示",
    appShortVersion: "26.7.19",
    buildVersion: "260719.4",
    macOSVersion: "Version 15.5",
    architecture: "arm64",
    screenId: "全部图片",
    region: { x: 0.1, y: 0.2, width: 0.3, height: 0.4 },
    anonymousInstallIdHash: "a".repeat(64),
    contact: null,
    diagnosticsIncluded: true,
    submittedAt: "2026-07-19T10:00:00Z",
  };
}

test("health endpoint", async () => {
  const response = await worker.fetch(new Request("https://example.com/health"), {}, { waitUntil() {} });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).ok, true);
});

test("validates privacy-safe feedback payload", () => {
  assert.equal(validateFeedbackPayload(validPayload()), null);
  assert.equal(validateFeedbackPayload({ ...validPayload(), message: "" }), "message_required");
  assert.equal(validateFeedbackPayload({ ...validPayload(), message: "x".repeat(5_001) }), "message_too_long");
  assert.equal(validateFeedbackPayload({ ...validPayload(), anonymousInstallIdHash: "raw-device-id" }), "invalid_install_id");
  assert.equal(validateFeedbackPayload({ ...validPayload(), region: { x: -1, y: 0, width: 1, height: 1 } }), "invalid_region");
});

test("requires multipart feedback", async () => {
  const response = await worker.fetch(
    new Request("https://example.com/v1/feedback", { method: "POST", body: "{}" }),
    {},
    { waitUntil() {} },
  );
  assert.equal(response.status, 415);
});
