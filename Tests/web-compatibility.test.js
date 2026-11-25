'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Blob, File } = require('node:buffer');

const source = fs.readFileSync(path.join(__dirname, '../SkincareInventory/WebCompatibility.js'), 'utf8');
const origin = 'https://skincare-k-test-20261115.pages.dev';
const xlsxMIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

function browser(options = {}) {
  const messages = [], revoked = [], alerts = [], warnings = [], events = new Map();
  let defaultClicks = 0, originalShares = 0, urlSequence = 0;
  class Anchor {
    constructor(href, download) { this.href = href; this.download = download === undefined ? '' : download; this.hasDownload = download !== undefined; }
    hasAttribute(name) { return name === 'download' && this.hasDownload; }
    closest(selector) { return selector === 'a[download]' && this.hasDownload ? this : null; }
    click() { defaultClicks++; }
  }
  class Reader {
    readAsDataURL(blob) {
      if (options.readerFails) { queueMicrotask(() => this.onerror()); return; }
      blob.arrayBuffer().then(bytes => {
        this.result = 'data:' + (blob.type || 'application/octet-stream') + ';base64,' + Buffer.from(bytes).toString('base64');
        this.onload();
      }).catch(() => this.onerror());
    }
  }
  const originalShare = function () { originalShares++; return Promise.resolve('original'); };
  const originalCanShare = function () { return 'original-can-share'; };
  const context = vm.createContext({
    Blob, File, FileReader: Reader, DOMException, HTMLAnchorElement: Anchor,
    location: { origin: options.origin || origin },
    navigator: { share: originalShare, canShare: originalCanShare },
    URL: {
      createObjectURL() { return 'blob:' + (options.origin || origin) + '/generated-' + (++urlSequence); },
      revokeObjectURL(url) { revoked.push(url); }
    },
    document: { addEventListener(name, callback, capture) { events.set(name, { callback, capture }); } },
    console: { warn(...args) { warnings.push(args); } },
    alert(message) { alerts.push(message); }
  });
  context.window = context;
  // vm contextifies its global object; compare against its own window value.
  vm.runInContext('top = window', context);
  if (options.iframe) context.top = {};
  if (!options.noBridge) context.webkit = { messageHandlers: { inventoryFiles: { postMessage(message) {
    if (options.postThrows) throw new Error('native unavailable');
    messages.push(JSON.parse(JSON.stringify(message)));
  } } } };
  vm.runInContext(source, context, { filename: 'WebCompatibility.js' });
  return {
    context, messages, revoked, alerts, warnings, events, Anchor, originalShare, originalCanShare,
    get defaultClicks() { return defaultClicks; }, get originalShares() { return originalShares; },
    rerun() { vm.runInContext(source, context); },
    complete(status = 'shared', index = 0, message) {
      context.__inventoryFileBridgeComplete(messages[index].requestId, { status, message });
    },
    download(blob, filename) {
      const url = context.URL.createObjectURL(blob);
      const anchor = new Anchor(url, filename);
      anchor.click();
      return { anchor, url };
    }
  };
}

async function until(predicate) {
  for (let attempt = 0; attempt < 30; attempt++) {
    if (predicate()) return;
    await new Promise(resolve => setImmediate(resolve));
  }
  assert.ok(predicate(), 'asynchronous file operation did not finish');
}

test('installs once on the trusted top frame and retains non-file web share', async () => {
  const app = browser();
  assert.equal(app.context.__inventoryFileBridgeVersion, 1);
  const share = app.context.navigator.share;
  app.rerun();
  assert.equal(app.context.navigator.share, share);
  assert.equal(app.context.navigator.canShare({ title: 'plain text' }), 'original-can-share');
  assert.equal(await app.context.navigator.share({ title: 'plain text' }), 'original');
  assert.equal(app.originalShares, 1);
  assert.equal(app.events.get('click').capture, true);
});

test('JSON download preserves real UTF-8 bytes after immediate object URL revocation', async () => {
  const app = browser();
  const json = JSON.stringify({ app: 'skincare-inventory-zero-data', products: [{ name: '测试面霜', qty: 2 }] });
  const { url } = app.download(new Blob([json], { type: 'application/json;charset=utf-8' }), '护肤品库存备份-20261125.json');
  app.context.URL.revokeObjectURL(url);
  await until(() => app.messages.length === 1);
  assert.equal(app.defaultClicks, 0, 'a Blob download must not navigate the WKWebView');
  assert.deepEqual(app.revoked, [url]);
  assert.equal(app.messages[0].filename, '护肤品库存备份-20261125.json');
  assert.equal(app.messages[0].mimeType, 'application/json');
  assert.equal(Buffer.from(app.messages[0].base64Data, 'base64').toString('utf8'), json);
  app.complete();
});

test('XLSX download preserves binary bytes and a Chinese filename', async () => {
  const app = browser();
  const bytes = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0, 0xff, 0x80, 0x81, 0x0a]);
  app.download(new Blob([bytes], { type: xlsxMIME }), '库存手记-2026-11-25.xlsx');
  await until(() => app.messages.length === 1);
  assert.equal(app.messages[0].mimeType, xlsxMIME);
  assert.equal(app.messages[0].filename, '库存手记-2026-11-25.xlsx');
  assert.deepEqual(Buffer.from(app.messages[0].base64Data, 'base64'), bytes);
  app.complete();
});

test('captures user clicks before navigation and stops the original click handler', async () => {
  const app = browser();
  const url = app.context.URL.createObjectURL(new Blob(['{}'], { type: 'application/json' }));
  const anchor = new app.Anchor(url, 'tap.json');
  const event = { target: { closest() { return anchor; } }, prevented: false, stopped: false,
    preventDefault() { this.prevented = true; }, stopImmediatePropagation() { this.stopped = true; } };
  app.events.get('click').callback(event);
  assert.equal(event.prevented, true);
  assert.equal(event.stopped, true);
  await until(() => app.messages.length === 1);
  app.complete();
});

test('file share resolves only after the native completion', async () => {
  const app = browser();
  const file = new File(['{"products":[]}'], '备份.json', { type: 'application/json' });
  assert.equal(app.context.navigator.canShare({ files: [file] }), true);
  let settled = false;
  const sharing = app.context.navigator.share({ files: [file] }).then(() => { settled = true; });
  await until(() => app.messages.length === 1);
  assert.equal(settled, false);
  app.complete();
  await sharing;
  assert.equal(settled, true);
});

test('native cancellation becomes AbortError, avoiding the website fallback download', async () => {
  const app = browser();
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  let fallbackDownloads = 0;
  const sharing = app.context.navigator.share({ files: [file] }).catch(error => {
    if (error.name !== 'AbortError') fallbackDownloads++;
    assert.equal(error.name, 'AbortError');
  });
  await until(() => app.messages.length === 1);
  app.complete('cancelled');
  await sharing;
  assert.equal(fallbackDownloads, 0);
});

test('repeated shares and download taps cannot present overlapping native panels', async () => {
  const app = browser();
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  const sharing = app.context.navigator.share({ files: [file] });
  await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'AbortError' });
  app.download(file, file.name);
  await until(() => app.messages.length === 1);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.messages.length, 1);
  assert.equal(app.context.navigator.canShare({ files: [file] }), true, 'busy must not trigger the website fallback path');
  assert.equal(app.defaultClicks, 0);
  app.complete();
  await sharing;
});

test('a native error releases the bridge for a subsequent share', async () => {
  const app = browser();
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  const first = app.context.navigator.share({ files: [file] });
  const rejection = assert.rejects(first, { name: 'AbortError', message: '测试错误' });
  await until(() => app.messages.length === 1);
  app.complete('error', 0, '测试错误');
  await rejection;
  const second = app.context.navigator.share({ files: [file] });
  await until(() => app.messages.length === 2);
  assert.notEqual(app.messages[0].requestId, app.messages[1].requestId);
  app.complete('shared', 1);
  await second;
});

test('a native share error does not activate the website fallback download', async () => {
  const app = browser();
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  let fallbackDownloads = 0;
  const sharing = app.context.navigator.share({ files: [file] }).catch(error => {
    if (error.name !== 'AbortError') {
      fallbackDownloads++;
      app.download(file, file.name);
    }
  });
  await until(() => app.messages.length === 1);
  app.complete('error', 0, '系统分享失败');
  await sharing;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(fallbackDownloads, 0);
  assert.equal(app.messages.length, 1);
  assert.equal(app.alerts.length, 0, 'native errors already have a native banner');
});

test('a native download error does not duplicate its visible error banner', async () => {
  const app = browser();
  app.download(new Blob(['{}'], { type: 'application/json' }), '备份.json');
  await until(() => app.messages.length === 1);
  app.complete('error', 0, '系统分享失败');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.alerts.length, 0);
  assert.equal(app.warnings.length, 1);
});

test('rejects empty, unsupported, mismatched and multi-file shares without native access', async () => {
  const app = browser();
  const files = [
    new File([], 'empty.json', { type: 'application/json' }),
    new File(['x'], 'photo.png', { type: 'image/png' }),
    new File(['{}'], 'fake.xlsx', { type: 'application/json' }),
    new File(['{}'], '.json', { type: 'application/json' }),
    new File(['{}'], '.hidden.json', { type: 'application/json' }),
    new File(['{}'], '...json', { type: 'application/json' })
  ];
  for (const file of files) {
    assert.equal(app.context.navigator.canShare({ files: [file] }), false);
    await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'NotSupportedError' });
  }
  assert.equal(app.context.navigator.canShare({ files: [files[0], files[0]] }), false);
  await assert.rejects(app.context.navigator.share({ files: [files[0], files[0]] }), { name: 'NotSupportedError' });
  assert.equal(app.messages.length, 0);
});

test('accepts the size boundary and rejects larger files before base64 encoding', async () => {
  const app = browser();
  const atLimit = new File([Buffer.alloc(20 * 1024 * 1024)], 'limit.json', { type: 'application/json' });
  const tooLarge = new File([atLimit, 'x'], 'large.json', { type: 'application/json' });
  assert.equal(app.context.navigator.canShare({ files: [atLimit] }), true);
  assert.equal(app.context.navigator.canShare({ files: [tooLarge] }), false);
  await assert.rejects(app.context.navigator.share({ files: [tooLarge] }), { name: 'NotSupportedError' });
  assert.equal(app.messages.length, 0);
});

test('sanitizes suggested filesystem paths and infers MIME for generic Blobs', async () => {
  const app = browser();
  app.download(new Blob(['{}'], { type: 'application/octet-stream' }), '../../目录\\中文:备份.JSON');
  await until(() => app.messages.length === 1);
  assert.equal(app.messages[0].filename, '中文_备份.json');
  assert.equal(app.messages[0].mimeType, 'application/json');
  app.complete();
});

test('truncates long Chinese filenames at the native 240 UTF-8 byte boundary', async () => {
  const app = browser();
  app.download(new Blob(['{}'], { type: 'application/json' }), '霜'.repeat(78) + 'a' + '霜'.repeat(20) + '.JSON');
  await until(() => app.messages.length === 1);
  const filename = app.messages[0].filename;
  assert.equal(filename, '霜'.repeat(78) + 'a.json');
  assert.equal(Buffer.byteLength(filename, 'utf8'), 240);
  app.complete();
});

test('keeps complete emoji when truncating a long filename', async () => {
  const app = browser();
  app.download(new Blob(['{}'], { type: 'application/json' }), '🧴'.repeat(58) + 'abc' + '🧴'.repeat(20) + '.json');
  await until(() => app.messages.length === 1);
  const filename = app.messages[0].filename;
  assert.equal(filename, '🧴'.repeat(58) + 'abc.json');
  assert.equal(Buffer.byteLength(filename, 'utf8'), 240);
  assert.equal(Buffer.from(filename, 'utf8').toString('utf8'), filename);
  app.complete();
});

test('untrusted origins, subframes, and missing native handlers preserve browser behavior', () => {
  for (const options of [
    { origin: 'https://evil.example' },
    { origin: 'http://skincare-k-test-20261115.pages.dev' },
    { origin: origin + '.evil.example' },
    { iframe: true },
    { noBridge: true }
  ]) {
    const app = browser(options);
    assert.equal(app.context.__inventoryFileBridgeVersion, undefined);
    assert.equal(app.context.navigator.share, app.originalShare);
    assert.equal(app.context.navigator.canShare, app.originalCanShare);
    assert.equal(app.events.size, 0);
  }
});

test('ordinary links and Blob links without download attributes keep their browser behavior', () => {
  const app = browser();
  new app.Anchor('https://example.org/file.json', 'file.json').click();
  const blobURL = app.context.URL.createObjectURL(new Blob(['{}'], { type: 'application/json' }));
  new app.Anchor(blobURL).click();
  assert.equal(app.defaultClicks, 2);
  assert.equal(app.messages.length, 0);
});

test('native callback ignores unknown request IDs', async () => {
  const app = browser();
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  let resolved = false;
  const sharing = app.context.navigator.share({ files: [file] }).then(() => { resolved = true; });
  await until(() => app.messages.length === 1);
  app.context.__inventoryFileBridgeComplete('__proto__', { status: 'shared' });
  app.context.__inventoryFileBridgeComplete('not-a-request', { status: 'shared' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(resolved, false);
  app.complete();
  await sharing;
});

test('FileReader failure never forwards a partial file and permits retry', async () => {
  const app = browser({ readerFails: true });
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'NotReadableError' });
  await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'NotReadableError' });
  assert.equal(app.messages.length, 0);
});

test('postMessage failure rejects rather than leaving a pending share forever', async () => {
  const app = browser({ postThrows: true });
  const file = new File(['{}'], '备份.json', { type: 'application/json' });
  await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'NotReadableError' });
  await assert.rejects(app.context.navigator.share({ files: [file] }), { name: 'NotReadableError' });
  assert.equal(app.messages.length, 0);
});
