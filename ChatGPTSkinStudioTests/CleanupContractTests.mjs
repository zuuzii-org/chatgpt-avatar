import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const cleanupSource = readFileSync(
  new URL("../ChatGPTSkinStudio/Resources/Injected/cleanup.js", import.meta.url),
  "utf8",
);

const STATE_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.state");
const RELOAD_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.reload");
const PAYLOAD_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.payload");
const BINDING_NAME_SYMBOL = Symbol.for(
  "com.zuuzii.chatgpt-skin.runtime-binding-name",
);
const BINDING_NAME = "__zuuziiSkinRuntime_cleanup_contract";

function runCleanup({ cancel, cleanup, nodes, anchorNodes = [] }) {
  const context = vm.createContext({
    document: {
      querySelectorAll: (selector) => (
        selector === "[data-zuuzii-anchor]" ? anchorNodes : nodes
      ),
    },
  });
  context[RELOAD_SYMBOL] = { cancel };
  context[STATE_SYMBOL] = { cleanup };
  context[PAYLOAD_SYMBOL] = { generation: "cleanup-contract" };
  context[BINDING_NAME_SYMBOL] = BINDING_NAME;
  context[BINDING_NAME] = () => {};

  const result = vm.runInContext(cleanupSource, context);
  return { context, result };
}

function assertGlobalsRemoved(context) {
  assert.equal(context[RELOAD_SYMBOL], undefined);
  assert.equal(context[STATE_SYMBOL], undefined);
  assert.equal(context[PAYLOAD_SYMBOL], undefined);
  assert.equal(context[BINDING_NAME_SYMBOL], undefined);
  assert.equal(Object.hasOwn(context, BINDING_NAME), false);
}

test("throwing reload cancel is audited while later teardown continues", () => {
  let cleanupCalls = 0;
  let removedNodes = 0;
  const { context, result } = runCleanup({
    cancel: () => {
      throw new Error("planned cancel failure");
    },
    cleanup: () => {
      cleanupCalls += 1;
      return { cleaned: true };
    },
    nodes: [
      { remove: () => { removedNodes += 1; } },
    ],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(
    Array.from(result.failures, (failure) => failure.step),
    ["reload.cancel"],
  );
  assert.match(result.failures[0].message, /planned cancel failure/);
  assert.equal(cleanupCalls, 1);
  assert.equal(removedNodes, 1);
  assert.equal(result.removedNodes, 1);
  assertGlobalsRemoved(context);
});

test("throwing state cleanup is audited while owner and global teardown continues", () => {
  let removedNodes = 0;
  const { context, result } = runCleanup({
    cancel: () => true,
    cleanup: () => {
      throw new Error("planned state cleanup failure");
    },
    nodes: [
      { remove: () => { removedNodes += 1; } },
    ],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(
    Array.from(result.failures, (failure) => failure.step),
    ["state.cleanup"],
  );
  assert.match(result.failures[0].message, /planned state cleanup failure/);
  assert.equal(removedNodes, 1);
  assert.equal(result.removedNodes, 1);
  assertGlobalsRemoved(context);
});

test("throwing owner removal does not stop teardown of later owned nodes", () => {
  let laterNodeRemoved = false;
  const { context, result } = runCleanup({
    cancel: () => true,
    cleanup: () => ({ cleaned: true }),
    nodes: [
      { remove: () => { throw new Error("planned node removal failure"); } },
      { remove: () => { laterNodeRemoved = true; } },
    ],
  });

  assert.equal(result.ok, false);
  assert.deepEqual(
    Array.from(result.failures, (failure) => failure.step),
    ["owned-node.remove[0]"],
  );
  assert.equal(laterNodeRemoved, true);
  assert.equal(result.removedNodes, 1);
  assertGlobalsRemoved(context);
});

test("schema v3.1 anchor attributes are removed without treating native nodes as owned", () => {
  const removedAttributes = [];
  const anchorNode = {
    removeAttribute: (name) => { removedAttributes.push(name); },
  };
  const { context, result } = runCleanup({
    cancel: () => true,
    cleanup: () => ({ cleaned: true }),
    nodes: [],
    anchorNodes: [anchorNode],
  });

  assert.equal(result.ok, true);
  assert.equal(result.removedNodes, 0);
  assert.deepEqual(removedAttributes, [
    "data-zuuzii-anchor",
    "data-zuuzii-anchor-generation",
  ]);
  assertGlobalsRemoved(context);
});
