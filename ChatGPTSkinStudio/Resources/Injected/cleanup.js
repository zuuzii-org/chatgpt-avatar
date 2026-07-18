(() => {
  "use strict";

  const STATE_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.state");
  const RUNTIME_BINDING_NAME_SYMBOL = Symbol.for(
    "com.zuuzii.chatgpt-skin.runtime-binding-name"
  );
  const RELOAD_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.reload");
  const PAYLOAD_SYMBOL = Symbol.for("com.zuuzii.chatgpt-skin.payload");
  const OWNER_ATTRIBUTE = "data-zuuzii-skin-owner";
  const failures = [];
  const MAX_FAILURES = 64;
  const MAX_FAILURE_MESSAGE_LENGTH = 512;

  const describeFailure = (error) => {
    try {
      const message = error && typeof error.message === "string"
        ? error.message
        : String(error);
      return message.slice(0, MAX_FAILURE_MESSAGE_LENGTH);
    } catch (_) {
      return "unknown teardown error";
    }
  };

  const recordFailure = (step, error) => {
    if (failures.length >= MAX_FAILURES) return;
    failures.push(Object.freeze({
      step,
      message: describeFailure(error),
    }));
  };

  const readGlobal = (key, step) => {
    try {
      return globalThis[key];
    } catch (error) {
      recordFailure(step, error);
      return undefined;
    }
  };

  const deleteGlobal = (key, step, expectedValue, requireIdentity) => {
    try {
      if (requireIdentity && globalThis[key] !== expectedValue) return;
      if (!delete globalThis[key]) {
        throw new Error("global property could not be deleted");
      }
    } catch (error) {
      recordFailure(step, error);
    }
  };

  const reloadState = readGlobal(RELOAD_SYMBOL, "reload.read");
  const state = readGlobal(STATE_SYMBOL, "state.read");
  let cleaned = false;
  let reloadCancelled = false;

  try {
    if (reloadState && typeof reloadState.cancel === "function") {
      reloadCancelled = reloadState.cancel("external-cleanup") === true;
    }
  } catch (error) {
    recordFailure("reload.cancel", error);
  }
  deleteGlobal(RELOAD_SYMBOL, "reload.delete", reloadState, true);

  try {
    if (state && typeof state.cleanup === "function") {
      const result = state.cleanup("external-cleanup");
      cleaned = result?.cleaned === true;
    }
  } catch (error) {
    recordFailure("state.cleanup", error);
  }

  let removedNodes = 0;
  let ownedNodes = [];
  try {
    ownedNodes = Array.from(document.querySelectorAll(`[${OWNER_ATTRIBUTE}]`));
  } catch (error) {
    recordFailure("owned-nodes.query", error);
  }
  for (let index = 0; index < ownedNodes.length; index += 1) {
    try {
      ownedNodes[index].remove();
      removedNodes += 1;
    } catch (error) {
      recordFailure(`owned-node.remove[${index}]`, error);
    }
  }

  // schema v3.1：皮肤崩溃残留防御——摘除我们打在原生元素上的锚点属性钩子。
  let anchorNodes = [];
  try {
    anchorNodes = Array.from(document.querySelectorAll("[data-zuuzii-anchor]"));
  } catch (error) {
    recordFailure("anchor-nodes.query", error);
  }
  for (let index = 0; index < anchorNodes.length; index += 1) {
    try {
      anchorNodes[index].removeAttribute("data-zuuzii-anchor");
      anchorNodes[index].removeAttribute("data-zuuzii-anchor-generation");
    } catch (error) {
      recordFailure(`anchor-node.remove-attribute[${index}]`, error);
    }
  }

  deleteGlobal(STATE_SYMBOL, "state.delete", state, true);
  deleteGlobal(PAYLOAD_SYMBOL, "payload.delete", undefined, false);
  const runtimeBindingName = readGlobal(
    RUNTIME_BINDING_NAME_SYMBOL,
    "runtime-binding-name.read"
  );
  if (
    typeof runtimeBindingName === "string"
    && runtimeBindingName.startsWith("__zuuziiSkinRuntime_")
    && runtimeBindingName.length <= 128
  ) {
    deleteGlobal(
      runtimeBindingName,
      "runtime-binding.delete",
      undefined,
      false
    );
  }
  deleteGlobal(
    RUNTIME_BINDING_NAME_SYMBOL,
    "runtime-binding-name.delete",
    undefined,
    false
  );
  return Object.freeze({
    ok: failures.length === 0,
    cleaned: reloadCancelled || cleaned || removedNodes > 0,
    reloadCancelled,
    removedNodes,
    failures: Object.freeze(failures.slice()),
  });
})();
