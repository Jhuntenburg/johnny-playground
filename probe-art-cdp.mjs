#!/usr/bin/env node

const cdpPort = process.env.ART_DEBUG_CDP_PORT || "9222";
const appUrl = process.env.ART_DEBUG_APP_URL || "http://127.0.0.1:8888/art.html";
const emulateWidth = process.env.ART_DEBUG_WIDTH ? Number(process.env.ART_DEBUG_WIDTH) : null;
const emulateHeight = process.env.ART_DEBUG_HEIGHT ? Number(process.env.ART_DEBUG_HEIGHT) : null;
const emulateDpr = process.env.ART_DEBUG_DPR ? Number(process.env.ART_DEBUG_DPR) : 3;
const emulateMobile = process.env.ART_DEBUG_MOBILE === "0" ? false : Boolean(emulateWidth && emulateHeight);
const expression = process.argv[2] || `(() => {
  const slider = document.getElementById("size-slider");
  const preview = document.getElementById("size-preview");
  const toolbar = document.getElementById("toolbar");
  const previewRect = preview ? preview.getBoundingClientRect() : null;
  const sliderRect = slider ? slider.getBoundingClientRect() : null;
  const toolbarRect = toolbar ? toolbar.getBoundingClientRect() : null;

  return {
    url: location.href,
    viewport: {
      innerWidth,
      innerHeight,
      devicePixelRatio,
      visualViewportScale: window.visualViewport ? window.visualViewport.scale : null
    },
    slider: slider ? {
      value: slider.value,
      min: slider.min,
      max: slider.max,
      width: sliderRect.width,
      height: sliderRect.height
    } : null,
    preview: preview ? {
      width: previewRect.width,
      height: previewRect.height,
      text: document.getElementById("size-label")?.textContent || null
    } : null,
    toolbar: toolbar ? {
      width: toolbarRect.width,
      height: toolbarRect.height
    } : null,
    activeElement: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null
  };
})()`;

const versionUrl = `http://127.0.0.1:${cdpPort}/json/list`;
const directWsUrl = process.env.ART_DEBUG_WS_URL || "";

function formatRemoteObject(remoteObject) {
  if (!remoteObject) return null;
  if ("value" in remoteObject) return remoteObject.value;
  if ("description" in remoteObject) return remoteObject.description;
  return remoteObject;
}

async function getTargetWebSocketUrl() {
  const response = await fetch(versionUrl);
  if (!response.ok) {
    throw new Error(`Could not load ${versionUrl}: ${response.status}`);
  }

  const pages = await response.json();
  const target = pages.find((page) => page.url === appUrl) || pages.find((page) => page.url.includes("art.html"));

  if (!target?.webSocketDebuggerUrl) {
    throw new Error(`Could not find a CDP target for ${appUrl}`);
  }

  return target.webSocketDebuggerUrl;
}

async function evaluateOnPage(wsUrl, jsExpression) {
  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let nextId = 1;
    const inflight = new Map();

    function send(method, params = {}) {
      const id = nextId++;
      return new Promise((innerResolve, innerReject) => {
        inflight.set(id, { method, resolve: innerResolve, reject: innerReject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    }

    ws.addEventListener("open", async () => {
      try {
        await send("Runtime.enable");
        await send("Page.enable");

        if (emulateWidth && emulateHeight) {
          await send("Emulation.setDeviceMetricsOverride", {
            mobile: emulateMobile,
            width: emulateWidth,
            height: emulateHeight,
            deviceScaleFactor: emulateDpr
          });
          await send("Emulation.setTouchEmulationEnabled", {
            enabled: emulateMobile,
            maxTouchPoints: emulateMobile ? 5 : 0
          });
        }

        const evaluation = await send("Runtime.evaluate", {
          expression: jsExpression,
          returnByValue: true,
          awaitPromise: true
        });

        ws.close();
        if (evaluation.exceptionDetails) {
          reject(new Error(evaluation.exceptionDetails.text || "Expression threw"));
          return;
        }

        resolve(formatRemoteObject(evaluation.result));
      } catch (error) {
        ws.close();
        reject(error);
      }
    });

    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (!message.id) return;

      const request = inflight.get(message.id);
      if (!request) return;
      inflight.delete(message.id);

      if (message.error) {
        request.reject(new Error(message.error.message || "CDP request failed"));
        return;
      }
      request.resolve(message.result);
    });

    ws.addEventListener("error", (event) => {
      reject(new Error(`WebSocket error: ${event.message || "unknown error"}`));
    });
  });
}

try {
  const wsUrl = directWsUrl || await getTargetWebSocketUrl();
  const result = await evaluateOnPage(wsUrl, expression);
  console.log(JSON.stringify(result, null, 2));
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
