// ZeroLose Chrome DevTools Protocol köprüsü.
// `ws` (RFC6455) ile Chrome'un CDP WebSocket'ine bağlanır; Swift tarafındaki
// `URLSessionWebSocketTask` aksine Chrome CDP frame'lerini güvenilir işler.
// Kullanım: node bridge.mjs <cdpPort>  →  stdin satırları, stdout JSON.
import WebSocket from "ws";

const port = Number(process.argv[2] || 9333);

async function getPageWS() {
  const res = await fetch(`http://127.0.0.1:${port}/json/list`);
  const targets = await res.json();
  const page = targets.find((t) => t.type === "page");
  if (!page) throw new Error("CDP 'page' target bulunamadı");
  return page.webSocketDebuggerUrl;
}

let ws;
let nextId = 0;
const pending = new Map();

function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
    setTimeout(() => {
      if (pending.has(id)) {
        pending.delete(id);
        reject(new Error(`CDP yanıt zaman aşımı: ${method}`));
      }
    }, 8000);
  });
}

function attach() {
  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      if (msg.id && pending.has(msg.id)) {
        const p = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message));
        else p.resolve(msg.result || {});
      }
    } catch {
      /* yutma — hatalı mesaj */
    }
  });
}

async function evalJS(expression) {
  const r = await send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  return r?.result?.value;
}

const commands = {
  navigate: async (url) => {
    await send("Page.navigate", { url });
    await new Promise((r) => setTimeout(r, 900));
    return `açıldı: ${url}`;
  },
  audit: async () => {
    const v = await evalJS(`(function(){
      var out=[];
      document.querySelectorAll('input,textarea,select,button,[role=button]').forEach(function(e,i){
        var t=(e.name||e.id||e.placeholder||e.textContent||'').trim();
        if(t) out.push('#'+i+' <'+e.tagName.toLowerCase()+'> '+t);
      });
      return out.slice(0,60).join('\\n');
    })()`);
    return v || "";
  },
  fill: async (selector, value) => {
    const v = await evalJS(`(function(){
      var el=document.querySelector(${JSON.stringify(selector)});
      if(!el) return 'NOT_FOUND';
      el.focus(); el.value=${JSON.stringify(value)};
      el.dispatchEvent(new Event('input',{bubbles:true}));
      el.dispatchEvent(new Event('change',{bubbles:true}));
      return 'FILLED';
    })()`);
    if (v === "NOT_FOUND") throw new Error(`alan bulunamadı: ${selector}`);
    return `dolduruldu: ${selector}`;
  },
  click: async (selector) => {
    const v = await evalJS(`(function(){
      var el=document.querySelector(${JSON.stringify(selector)});
      if(!el) return 'NOT_FOUND';
      el.scrollIntoView({block:'center'}); el.click(); return 'CLICKED';
    })()`);
    if (v === "NOT_FOUND") throw new Error(`öğe bulunamadı: ${selector}`);
    return `tıklandı: ${selector}`;
  },
  evaluate: async (expression) => String(await evalJS(expression)),
  read: async (selector) => {
    const v = await evalJS(`(document.querySelector(${JSON.stringify(selector)})||{}).value || ''`);
    return String(v || "");
  },
  text: async (needle) => Boolean(await evalJS(`document.body.innerText.includes(${JSON.stringify(needle)})`)),
};

async function main() {
  const pageUrl = await getPageWS();
  ws = new WebSocket(pageUrl);
  await new Promise((res, rej) => {
    ws.on("open", res);
    ws.on("error", rej);
  });
  attach();
  console.log("READY " + pageUrl);

  const rl = (await import("node:readline")).createInterface({
    input: process.stdin,
    terminal: false,
    crlfDelay: Infinity,
  });
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const [cmd, ...rest] = trimmed.split("\t");
      const args = JSON.parse(rest[0] || "[]");
      const fn = commands[cmd];
      if (!fn) throw new Error(`bilinmeyen komut: ${cmd}`);
      const result = await fn(...args);
      console.log(JSON.stringify({ ok: true, cmd, result }));
    } catch (e) {
      console.log(JSON.stringify({ ok: false, cmd: trimmed.split("\t")[0], error: e.message }));
    }
  }
  process.exit(0);
}

main().catch((e) => {
  console.error("BRIDGE_FATAL " + e.message);
  process.exit(1);
});
