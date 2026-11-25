/*
 * The site remains unchanged. This document-start adapter hands its existing
 * JSON/XLSX Blob downloads to the app's native file share controller.
 */
(function () {
  'use strict';

  var TRUSTED_ORIGIN = 'https://skincare-k-test-20261115.pages.dev';
  var MAX_FILE_BYTES = 20 * 1024 * 1024;
  var JSON_MIME = 'application/json';
  var XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  var handler;
  try {
    handler = window.webkit && window.webkit.messageHandlers &&
      window.webkit.messageHandlers.inventoryFiles;
    if (window.top !== window || window.location.origin !== TRUSTED_ORIGIN ||
        !handler || typeof handler.postMessage !== 'function' ||
        window.__inventoryFileBridgeVersion) return;
  } catch (_) {
    return;
  }

  var objectURLs = new Map();
  var pending = Object.create(null);
  var activeRequest = null;
  var sequence = 0;
  var originalCreate = URL.createObjectURL.bind(URL);
  var originalRevoke = URL.revokeObjectURL.bind(URL);
  var originalClick = HTMLAnchorElement.prototype.click;
  var originalShare = typeof navigator.share === 'function' ? navigator.share.bind(navigator) : null;
  var originalCanShare = typeof navigator.canShare === 'function' ? navigator.canShare.bind(navigator) : null;

  function failure(name, message) {
    return new DOMException(message, name);
  }

  function fileDetails(blob, proposedName) {
    if (!(blob instanceof Blob) || !Number.isFinite(blob.size) || blob.size <= 0) {
      throw failure('NotSupportedError', '无法分享空文件或无效文件。');
    }
    if (blob.size > MAX_FILE_BYTES) {
      throw failure('NotSupportedError', '文件超过 20 MB，请减少内容后重试。');
    }
    // A download attribute is a suggested name, never a filesystem path.
    var filename = String(proposedName || '').replace(/\\/g, '/').split('/').pop()
      .replace(/[\u0000-\u001f\u007f:]/g, '_').trim();
    var extension = /\.(json|xlsx)$/i.exec(filename);
    if (!extension || filename.length === extension[0].length) {
      throw failure('NotSupportedError', '仅支持 JSON 备份和 Excel 表格。');
    }
    var suffix = extension[0].toLowerCase();
    var basename = filename.slice(0, -extension[0].length);
    filename = Array.from(basename).slice(0, 150).join('') + suffix;
    var expectedMIME = suffix === '.json' ? JSON_MIME : XLSX_MIME;
    var declaredMIME = String(blob.type || '').split(';')[0].trim().toLowerCase();
    if (declaredMIME && declaredMIME !== 'application/octet-stream' && declaredMIME !== expectedMIME) {
      throw failure('NotSupportedError', '文件类型与扩展名不一致。');
    }
    return { filename: filename, mimeType: expectedMIME };
  }

  function settle(requestId, result) {
    if (typeof requestId !== 'string' || !pending[requestId]) return;
    var operation = pending[requestId];
    delete pending[requestId];
    if (activeRequest === requestId) activeRequest = null;
    if (result && result.status === 'shared') {
      operation.resolve();
    } else if (result && result.status === 'cancelled') {
      operation.reject(failure('AbortError', '已取消分享。'));
    } else {
      var error = failure('OperationError', result && typeof result.message === 'string' ?
        result.message : '文件分享失败，请重试。');
      // The native coordinator already presents a visible error banner.
      error.inventoryNativeHandled = true;
      operation.reject(error);
    }
  }

  function sendFile(blob, filename) {
    var details;
    try { details = fileDetails(blob, filename); }
    catch (error) { return Promise.reject(error); }
    if (activeRequest !== null) {
      // AbortError deliberately suppresses the site's automatic backup-download
      // fallback when a second tap occurs while the first share sheet is open.
      return Promise.reject(failure('AbortError', '请先完成当前文件操作。'));
    }
    var requestId = 'inventory-file-' + (++sequence);
    activeRequest = requestId;
    return new Promise(function (resolve, reject) {
      pending[requestId] = { resolve: resolve, reject: reject };
      var reader = new FileReader();
      function readFailed(message) {
        delete pending[requestId];
        if (activeRequest === requestId) activeRequest = null;
        reject(failure('NotReadableError', message));
      }
      reader.onerror = function () { readFailed('无法读取导出文件，请重试。'); };
      reader.onabort = function () { readFailed('文件读取已取消。'); };
      reader.onload = function () {
        if (!pending[requestId]) return;
        var result = reader.result;
        if (typeof result !== 'string' || result.indexOf(';base64,') < 0) {
          readFailed('无法编码导出文件，请重试。');
          return;
        }
        try {
          handler.postMessage({
            requestId: requestId,
            filename: details.filename,
            mimeType: details.mimeType,
            base64Data: result.slice(result.indexOf(',') + 1)
          });
        } catch (_) {
          readFailed('无法打开系统分享菜单，请重试。');
        }
      };
      try { reader.readAsDataURL(blob); }
      catch (_) { readFailed('无法读取导出文件，请重试。'); }
    });
  }

  function reportDownloadFailure(error) {
    if (!error || error.name === 'AbortError') return;
    if (window.console && typeof window.console.warn === 'function') {
      window.console.warn('Inventory file export failed:', error.message);
    }
    if (!error.inventoryNativeHandled && typeof window.alert === 'function') {
      window.alert(error.message || '文件导出失败，请重试。');
    }
  }

  function interceptDownload(anchor) {
    if (!anchor || !anchor.hasAttribute('download')) return false;
    var blob = objectURLs.get(anchor.href);
    if (!blob) return false;
    // Keep this Blob alive before the website revokes its object URL. The file
    // conversion is asynchronous, and the original site revokes JSON URLs fast.
    var filename = anchor.download;
    sendFile(blob, filename).catch(reportDownloadFailure);
    return true;
  }

  URL.createObjectURL = function (object) {
    var url = originalCreate(object);
    if (object instanceof Blob) objectURLs.set(url, object);
    return url;
  };
  URL.revokeObjectURL = function (url) {
    objectURLs.delete(String(url));
    return originalRevoke(url);
  };
  HTMLAnchorElement.prototype.click = function () {
    if (interceptDownload(this)) return;
    return originalClick.apply(this, arguments);
  };
  document.addEventListener('click', function (event) {
    var target = event.target;
    var anchor = target && typeof target.closest === 'function' ? target.closest('a[download]') : null;
    if (interceptDownload(anchor)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);

  Object.defineProperty(navigator, 'canShare', {
    configurable: true,
    value: function (data) {
      if (data && data.files !== undefined) {
        try {
          if (!Array.isArray(data.files) || data.files.length !== 1) return false;
          fileDetails(data.files[0], data.files[0].name);
          return true;
        } catch (_) { return false; }
      }
      return originalCanShare ? originalCanShare(data) : false;
    }
  });
  Object.defineProperty(navigator, 'share', {
    configurable: true,
    value: function (data) {
      if (data && data.files !== undefined) {
        if (!Array.isArray(data.files) || data.files.length !== 1) {
          return Promise.reject(failure('NotSupportedError', '每次仅支持分享一个备份或表格。'));
        }
        return sendFile(data.files[0], data.files[0].name);
      }
      return originalShare ? originalShare(data) : Promise.reject(failure('NotSupportedError', '当前内容不支持分享。'));
    }
  });
  Object.defineProperty(window, '__inventoryFileBridgeComplete', {
    configurable: false,
    writable: false,
    value: settle
  });
  Object.defineProperty(window, '__inventoryFileBridgeVersion', { value: 1 });
})();
