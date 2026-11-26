// Faz 0 agent'ı: Frida Gadget ile hedef uygulamanın içinde çalışır.
// Host köprüsü (prototype/host) bu RPC uçlarını çağırır:
//   screen()            → ekran bilgisi
//   observe({...})      → ekran görüntüsü + erişilebilirlik eleman listesi + uygulama durumu
//   act({type, target}) → eylem (Faz 0: yalnızca "tap")
//
// Faz 0'da gerçek dokunma olayı (IOHIDEvent) sentezlenmez; bu Faz 1'de Hammer ile gelir.
// "tap" bunun yerine semantik olarak uygulanır: UIControl eylemleri, tablo/collection hücre
// seçimi, accessibilityActivate ve WKWebView için JavaScript tıklaması.

import ObjC from "frida-objc-bridge";

// GumJS'in console'u; @types/frida-gum bunu tanımlamıyor.
declare const console: { log(...args: unknown[]): void };

type Obj = ObjC.Object;

interface Rect { x: number; y: number; w: number; h: number; }

interface Element {
    id: string;
    kind: "ax" | "webview";
    cls: string;
    label: string | null;
    value: string | null;
    hint: string | null;
    identifier: string | null;
    traits: string[];
    frame: Rect;
    interactive: boolean;
    enabled: boolean;
}

interface Found { el: Element; obj: Obj; }

interface ActResult {
    ok: boolean;
    method?: string;
    code?: string;
    message?: string;
    detail?: unknown;
}

type Target = string | { x: number; y: number };

interface Action { type: string; target: Target; }

interface ObserveOptions {
    screenshot?: boolean;
    scale?: number;
    maxElements?: number;
}

const TRAITS: [string, number][] = [
    ["button", 1 << 0],
    ["link", 1 << 1],
    ["image", 1 << 2],
    ["selected", 1 << 3],
    ["playsSound", 1 << 4],
    ["keyboardKey", 1 << 5],
    ["staticText", 1 << 6],
    ["summaryElement", 1 << 7],
    ["notEnabled", 1 << 8],
    ["updatesFrequently", 1 << 9],
    ["searchField", 1 << 10],
    ["startsMediaSession", 1 << 11],
    ["adjustable", 1 << 12],
    ["allowsDirectInteraction", 1 << 13],
    ["causesPageTurn", 1 << 14],
    ["header", 1 << 16],
];

const INTERACTIVE_TRAITS = new Set(["button", "link", "keyboardKey", "searchField", "adjustable", "allowsDirectInteraction"]);

const UIControlEventTouchUpInside = 1 << 6;
const UIControlEventValueChanged = 1 << 12;
const NSNotFound = "9223372036854775807";

// ---------------------------------------------------------------------------
// Yardımcılar

function cls(name: string): Obj | null {
    return ObjC.classes[name] ?? null;
}

function num(v: unknown): number {
    if (typeof v === "number") return v;
    if (typeof v === "boolean") return v ? 1 : 0;
    if (v === null || v === undefined) return 0;
    return Number((v as { toString(): string }).toString());
}

function isNil(o: unknown): boolean {
    if (o === null || o === undefined) return true;
    const h = (o as Obj).handle;
    return h !== undefined && h.isNull();
}

function asObj(v: unknown): Obj {
    return v instanceof ObjC.Object ? v : new ObjC.Object(v as NativePointer);
}

function str(o: unknown): string | null {
    if (isNil(o)) return null;
    const s = (o as Obj).toString();
    return s.length > 0 ? s : null;
}

function responds(o: Obj, selector: string): boolean {
    return !!o.respondsToSelector_(ObjC.selector(selector));
}

function kindOf(o: Obj, className: string): boolean {
    const c = cls(className);
    return c !== null && !!o.isKindOfClass_(c);
}

function rectOf(r: unknown): Rect {
    const a = r as [[number, number], [number, number]];
    return { x: num(a[0][0]), y: num(a[0][1]), w: num(a[1][0]), h: num(a[1][1]) };
}

function contains(r: Rect, x: number, y: number): boolean {
    return x >= r.x && y >= r.y && x <= r.x + r.w && y <= r.y + r.h;
}

function hashId(s: string): string {
    // FNV-1a 32 bit: kısa ve aynı girdiye her zaman aynı ID
    let h = 0x811c9dc5;
    for (let i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return "e" + h.toString(16).padStart(8, "0");
}

function onMain<T>(fn: () => T | Promise<T>): Promise<T> {
    return new Promise((resolve, reject) => {
        ObjC.schedule(ObjC.mainQueue, () => {
            try {
                Promise.resolve(fn()).then(resolve, reject);
            } catch (e) {
                reject(e);
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Erişilebilirlik otomasyonu (SwiftUI ağacının oluşması için gerekebilir)

let axAutomation = false;

function enableAccessibilityAutomation(): void {
    try {
        const lib = Module.load("/usr/lib/libAccessibility.dylib");
        for (const name of ["_AXSSetAutomationEnabled", "_AXSApplicationAccessibilitySetEnabled"]) {
            const addr = lib.findExportByName(name);
            if (addr === null) continue;
            new NativeFunction(addr, "void", ["int"])(1);
            if (name === "_AXSSetAutomationEnabled") axAutomation = true;
        }
    } catch (e) {
        console.log(`[agent] AX otomasyonu açılamadı: ${e}`);
    }
}

// ---------------------------------------------------------------------------
// Pencereler ve ekran

function appWindows(): Obj[] {
    const app = cls("UIApplication")!.sharedApplication();
    const scenes = app.connectedScenes().allObjects();
    const out: Obj[] = [];
    for (let i = 0; i < num(scenes.count()); i++) {
        const scene = scenes.objectAtIndex_(i);
        if (!kindOf(scene, "UIWindowScene")) continue;
        // 0 = foregroundActive, 1 = foregroundInactive
        if (num(scene.activationState()) > 1) continue;
        const windows = scene.windows();
        for (let j = 0; j < num(windows.count()); j++) {
            const w = windows.objectAtIndex_(j);
            if (!w.isHidden()) out.push(w);
        }
    }
    out.sort((a, b) => num(a.windowLevel()) - num(b.windowLevel()));
    return out;
}

function screenSpace(): Obj {
    return cls("UIScreen")!.mainScreen().coordinateSpace();
}

function screenInfo() {
    const app = cls("UIApplication")!.sharedApplication();
    const screen = cls("UIScreen")!.mainScreen();
    const bounds = rectOf(screen.bounds());
    const windows = appWindows();
    const key = windows.find(w => w.isKeyWindow()) ?? windows[windows.length - 1] ?? null;
    let orientation = 0;
    let safeArea = { top: 0, left: 0, bottom: 0, right: 0 };
    if (key !== null) {
        const scene = key.windowScene();
        if (!isNil(scene)) orientation = num(scene.interfaceOrientation());
        const ins = key.safeAreaInsets() as number[];
        safeArea = { top: num(ins[0]), left: num(ins[1]), bottom: num(ins[2]), right: num(ins[3]) };
    }
    const states = ["active", "inactive", "background"];
    return {
        width: bounds.w,
        height: bounds.h,
        scale: num(screen.scale()),
        orientation: ["unknown", "portrait", "portraitUpsideDown", "landscapeRight", "landscapeLeft"][orientation] ?? "unknown",
        safeArea,
        units: "points",
        app: {
            bundleId: str(cls("NSBundle")!.mainBundle().bundleIdentifier()),
            state: states[num(app.applicationState())] ?? "unknown",
        },
        axAutomation,
    };
}

// ---------------------------------------------------------------------------
// Ekran görüntüsü

function screenshotBase64(scale: number): string {
    const screen = cls("UIScreen")!.mainScreen();
    const bounds = screen.bounds();
    const format = cls("UIGraphicsImageRendererFormat")!.preferredFormat();
    format.setScale_(scale);
    const renderer = cls("UIGraphicsImageRenderer")!.alloc().initWithBounds_format_(bounds, format);
    const windows = appWindows();
    const block = new ObjC.Block({
        retType: "void",
        argTypes: ["object"],
        implementation: () => {
            for (const w of windows) {
                w.drawViewHierarchyInRect_afterScreenUpdates_(w.frame(), false);
            }
        },
    });
    const data = renderer.PNGDataWithActions_(block);
    const b64 = data.base64EncodedStringWithOptions_(0).toString();
    renderer.release();
    return b64;
}

// ---------------------------------------------------------------------------
// Erişilebilirlik ağacı

function traitsOf(o: Obj): string[] {
    const bits = BigInt(o.accessibilityTraits().toString());
    return TRAITS.filter(([, b]) => (bits & BigInt(b)) !== 0n).map(([n]) => n);
}

function describe(o: Obj, path: string): Element {
    const identifier = responds(o, "accessibilityIdentifier") ? str(o.accessibilityIdentifier()) : null;
    const traits = traitsOf(o);
    const isControl = kindOf(o, "UIControl");
    const isTextInput = kindOf(o, "UITextField") || kindOf(o, "UITextView");
    let enabled = !traits.includes("notEnabled");
    if (isControl) enabled = enabled && !!o.isEnabled();
    const className = o.$className;
    return {
        id: hashId(identifier !== null ? `${className}#${identifier}` : `${className}@${path}`),
        kind: "ax",
        cls: className,
        label: str(o.accessibilityLabel()),
        value: str(o.accessibilityValue()),
        hint: str(o.accessibilityHint()),
        identifier,
        traits,
        frame: rectOf(o.accessibilityFrame()),
        interactive: isControl || isTextInput || traits.some(t => INTERACTIVE_TRAITS.has(t)),
        enabled,
    };
}

function describeWebView(o: Obj, path: string): Element {
    const frame = rectOf(o.convertRect_toCoordinateSpace_(o.bounds(), screenSpace()));
    const identifier = str(o.accessibilityIdentifier());
    return {
        id: hashId(identifier !== null ? `WKWebView#${identifier}` : `WKWebView@${path}`),
        kind: "webview",
        cls: o.$className,
        label: str(o.title()),
        value: str(o.URL()?.absoluteString?.()),
        hint: "WebView içeriği koordinatla hedeflenir (Faz 0)",
        identifier,
        traits: [],
        frame,
        interactive: true,
        enabled: true,
    };
}

function collect(maxElements: number): Found[] {
    const out: Found[] = [];
    const UIView = cls("UIView")!;
    const visit = (o: Obj, path: string, depth: number): void => {
        if (out.length >= maxElements || depth > 80 || isNil(o)) return;
        const isView = !!o.isKindOfClass_(UIView);
        if (isView && (o.isHidden() || num(o.alpha()) < 0.01)) return;
        if (o.accessibilityElementsHidden()) return;

        if (isView && kindOf(o, "WKWebView")) {
            out.push({ el: describeWebView(o, path), obj: o });
            return;
        }
        if (o.isAccessibilityElement()) {
            const el = describe(o, path);
            if (el.frame.w > 0 && el.frame.h > 0) out.push({ el, obj: o });
            return;
        }

        const axKids = o.accessibilityElements();
        if (!isNil(axKids) && num(axKids.count()) > 0) {
            for (let i = 0; i < num(axKids.count()); i++) visit(axKids.objectAtIndex_(i), `${path}/a${i}`, depth + 1);
            return;
        }
        const count = o.accessibilityElementCount();
        const countStr = count.toString();
        if (countStr !== "0" && countStr !== NSNotFound) {
            const n = Math.min(num(count), 500);
            for (let i = 0; i < n; i++) visit(o.accessibilityElementAtIndex_(i), `${path}/c${i}`, depth + 1);
            return;
        }
        if (isView) {
            const subs = o.subviews();
            for (let i = 0; i < num(subs.count()); i++) visit(subs.objectAtIndex_(i), `${path}/${i}`, depth + 1);
        }
    };
    appWindows().forEach((w, i) => visit(w, `w${i}`, 0));
    return out;
}

// ---------------------------------------------------------------------------
// Eylemler

const pendingBlocks = new Set<ObjC.Block>();

function ancestor(view: Obj | null, className: string): Obj | null {
    let v = view;
    while (v !== null && !isNil(v)) {
        if (kindOf(v, className)) return v;
        const s = v.superview();
        v = isNil(s) ? null : s;
    }
    return null;
}

function hitTest(x: number, y: number): Obj | null {
    const space = screenSpace();
    const windows = appWindows().reverse(); // en üstteki pencere önce
    for (const w of windows) {
        const p = w.convertPoint_fromCoordinateSpace_([x, y], space);
        const hit = w.hitTest_withEvent_(p, null);
        if (!isNil(hit)) return hit;
    }
    return null;
}

function webViewClick(webView: Obj, x: number, y: number): Promise<ActResult> {
    const p = webView.convertPoint_fromCoordinateSpace_([x, y], screenSpace()) as number[];
    const inset = webView.scrollView().adjustedContentInset() as number[];
    const cx = num(p[0]) - num(inset[1]);
    const cy = num(p[1]) - num(inset[0]);
    const js = `(function(x,y){var e=document.elementFromPoint(x,y);if(!e)return 'none';` +
        `if(e.focus)e.focus();if(e.click)e.click();else e.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:x,clientY:y}));` +
        `return e.tagName+(e.id?'#'+e.id:'');})(${cx},${cy})`;
    return new Promise(resolve => {
        const block: ObjC.Block = new ObjC.Block({
            retType: "void",
            argTypes: ["object", "object"],
            implementation: (result: unknown, error: unknown) => {
                pendingBlocks.delete(block);
                const res = isNil(result) ? null : asObj(result).toString();
                if (!isNil(error)) {
                    resolve({ ok: false, method: "webview-js", code: "webview_error", message: asObj(error).toString() });
                } else if (res === "none") {
                    resolve({ ok: false, method: "webview-js", code: "not_hittable", message: "Bu noktada DOM elemanı yok" });
                } else {
                    resolve({ ok: true, method: "webview-js", detail: res });
                }
            },
        });
        pendingBlocks.add(block);
        webView.evaluateJavaScript_completionHandler_(js, block);
    });
}

function selectCell(hit: Obj): ActResult | null {
    const tableCell = ancestor(hit, "UITableViewCell");
    if (tableCell !== null) {
        const table = ancestor(tableCell, "UITableView");
        if (table === null) return null;
        const ip = table.indexPathForCell_(tableCell);
        if (isNil(ip)) return null;
        table.selectRowAtIndexPath_animated_scrollPosition_(ip, false, 0);
        const d = table.delegate();
        if (!isNil(d) && responds(d, "tableView:didSelectRowAtIndexPath:")) d.tableView_didSelectRowAtIndexPath_(table, ip);
        return { ok: true, method: "table-select" };
    }
    const colCell = ancestor(hit, "UICollectionViewCell");
    if (colCell !== null) {
        const col = ancestor(colCell, "UICollectionView");
        if (col === null) return null;
        const ip = col.indexPathForCell_(colCell);
        if (isNil(ip)) return null;
        col.selectItemAtIndexPath_animated_scrollPosition_(ip, false, 0);
        const d = col.delegate();
        if (!isNil(d) && responds(d, "collectionView:didSelectItemAtIndexPath:")) d.collectionView_didSelectItemAtIndexPath_(col, ip);
        return { ok: true, method: "collection-select" };
    }
    return null;
}

function activateAt(x: number, y: number): ActResult | null {
    const candidates = collect(2000)
        .filter(f => f.el.kind === "ax" && contains(f.el.frame, x, y))
        .sort((a, b) => a.el.frame.w * a.el.frame.h - b.el.frame.w * b.el.frame.h);
    for (const c of candidates) {
        if (c.obj.accessibilityActivate()) return { ok: true, method: "ax-activate", detail: c.el.id };
    }
    return null;
}

async function tapPoint(x: number, y: number): Promise<ActResult> {
    const hit = hitTest(x, y);
    if (hit === null) return { ok: false, code: "not_hittable", message: `(${x}, ${y}) noktasında görünür bir view yok` };

    const webView = ancestor(hit, "WKWebView");
    if (webView !== null) return webViewClick(webView, x, y);

    const sw = ancestor(hit, "UISwitch");
    if (sw !== null && sw.isEnabled()) {
        sw.setOn_animated_(!sw.isOn(), true);
        sw.sendActionsForControlEvents_(UIControlEventValueChanged);
        return { ok: true, method: "switch-toggle" };
    }
    const textInput = ancestor(hit, "UITextField") ?? ancestor(hit, "UITextView");
    if (textInput !== null) {
        textInput.becomeFirstResponder();
        return { ok: true, method: "focus" };
    }
    const control = ancestor(hit, "UIControl");
    if (control !== null) {
        if (!control.isEnabled()) return { ok: false, code: "not_enabled", message: "Kontrol devre dışı" };
        control.sendActionsForControlEvents_(UIControlEventTouchUpInside);
        return { ok: true, method: "control-action" };
    }
    const cell = selectCell(hit);
    if (cell !== null) return cell;

    const ax = activateAt(x, y);
    if (ax !== null) return ax;

    return { ok: false, code: "not_hittable", message: `Dokunulan view (${hit.$className}) için semantik eylem bulunamadı` };
}

async function tap(target: Target): Promise<ActResult> {
    if (typeof target === "string") {
        const found = collect(2000).find(f => f.el.id === target);
        if (found === undefined) return { ok: false, code: "element_not_found", message: `Eleman yok: ${target}` };
        const f = found.el.frame;
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        if (found.el.kind === "ax" && !kindOf(found.obj, "UIControl") && found.obj.accessibilityActivate()) {
            return { ok: true, method: "ax-activate", detail: target };
        }
        const res = await tapPoint(cx, cy);
        return { ...res, detail: res.detail ?? { id: target, x: cx, y: cy } };
    }
    if (typeof target?.x !== "number" || typeof target?.y !== "number") {
        return { ok: false, code: "bad_target", message: "target bir eleman ID'si ya da {x, y} olmalı" };
    }
    return tapPoint(target.x, target.y);
}

// ---------------------------------------------------------------------------
// RPC

rpc.exports = {
    ping(): string {
        return "pong";
    },

    screen() {
        return onMain(() => screenInfo());
    },

    observe(options: ObserveOptions = {}) {
        const { screenshot = true, scale = 1, maxElements = 400 } = options;
        return onMain(() => {
            const info = screenInfo();
            const elements = collect(maxElements).map(f => f.el);
            return {
                screen: info,
                elements,
                truncated: elements.length >= maxElements,
                screenshot: screenshot ? { format: "png", scale, data: screenshotBase64(scale) } : null,
            };
        });
    },

    act(action: Action) {
        return onMain(async (): Promise<ActResult> => {
            const app = cls("UIApplication")!.sharedApplication();
            if (num(app.applicationState()) === 2) {
                return { ok: false, code: "app_backgrounded", message: "Uygulama arka planda" };
            }
            switch (action?.type) {
                case "tap":
                    return tap(action.target);
                default:
                    return { ok: false, code: "unsupported_action", message: `Faz 0'da desteklenmiyor: ${action?.type}` };
            }
        });
    },
};

if (ObjC.available) {
    ObjC.schedule(ObjC.mainQueue, enableAccessibilityAutomation);
    console.log("[agent] yüklendi");
} else {
    console.log("[agent] ObjC çalışma zamanı yok");
}
