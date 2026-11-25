/* Only injected by Debug builds with the explicit -ui-testing launch argument.
 * Runs on the genuine site in a disposable simulator, using fictional data. */
(function () {
  'use strict';
  if (window.top !== window || location.origin !== 'https://skincare-k-test-20261115.pages.dev') return;
  function install() {
    if (!window.__skincare || !window.__inventoryFileBridgeVersion) {
      setTimeout(install, 100); return;
    }
    var api = window.__skincare;
    var panel = document.createElement('section');
    panel.id = 'inventory-ui-tests';
    panel.setAttribute('aria-label', 'Inventory test harness');
    panel.style.cssText = 'position:fixed;inset:60px 12px 60px;z-index:2147483647;overflow:auto;background:#101b16;color:white;padding:14px;border:2px solid #a6c7a8;font:16px sans-serif;';
    var status = document.createElement('p');
    status.setAttribute('role', 'status');
    status.style.cssText = 'min-height:40px;white-space:pre-wrap;';
    panel.appendChild(status);
    function say(text) { status.textContent = text; }
    function button(label, run) {
      var element = document.createElement('button');
      element.textContent = label;
      element.style.cssText = 'display:block;width:100%;min-height:44px;margin:7px 0;border:1px solid #667e68;border-radius:6px;color:white;background:#253d2c;font-size:16px;';
      element.onclick = run;
      panel.appendChild(element);
    }
    var fixture = {
      app: 'skincare-inventory-zero-data', v: 1, exportedAt: '2026-11-25T00:00:00.000Z',
      products: [{id:991001,name:'模拟器测试面霜',brand:'虚构品牌',category:'面霜',unit:'瓶',spec:'50g',qtyText:'1瓶',sealed:1,inUse:0,used:0,buyDate:'2026-11-11',expiryDate:'2029-08-30',price:{cost:50},note:'仅用于自动测试'}],
      logs: [], trash: []
    };
    button('Test confirm', function () { say('confirm:' + window.confirm('Test confirmation')); });
    button('Test prompt', function () { say('prompt:' + String(window.prompt('Test remark', 'fixture'))); });
    button('Test share JSON', function () {
      say('share:pending');
      var file = new File([JSON.stringify(fixture)], '测试备份.json', {type:'application/json'});
      navigator.share({files:[file]}).then(function () {say('share:shared');},function(error){say('share:'+error.name);});
    });
    button('Test download JSON', function () {
      document.getElementById('btn-export').click();
    });
    button('Test download XLSX', async function () {
      var blob=await InventoryExcel.create(api.excelRows());
      var zip=await JSZip.loadAsync(blob);
      var parser=new DOMParser();
      var inventory=parser.parseFromString(await zip.file('xl/worksheets/sheet1.xml').async('string'),'application/xml');
      var prices=parser.parseFromString(await zip.file('xl/worksheets/sheet2.xml').async('string'),'application/xml');
      function cell(doc, ref) {var node=doc.querySelector('c[r="'+ref+'"]');return node ? node.textContent : '';}
      if(cell(inventory,'B2')!=='模拟器测试面霜' || cell(inventory,'I2')!=='1' || cell(prices,'W2')!=='50') {
        say('xlsx:content-mismatch'); return;
      }
      say('xlsx:verified-name-stock-cost');
      var anchor=document.createElement('a'); anchor.href=URL.createObjectURL(blob);
      anchor.download='测试库存.xlsx'; anchor.click(); URL.revokeObjectURL(anchor.href);
    });
    button('Test import fixture', function () {
      var file = new File([JSON.stringify(fixture)], '测试导入.json', {type:'application/json'});
      document.getElementById('file-input').onchange({target:{files:[file],value:''}});
      say('import:pending');
    });
    button('Test invalid import', function () {
      var file = new File(['{"app":"wrong","v":1,"products":[],"logs":[]}'], '错误备份.json', {type:'application/json'});
      document.getElementById('file-input').onchange({target:{files:[file],value:''}});
      setTimeout(function(){say('invalid-import:stock='+api.state().products.length);},300);
    });
    button('Test inspect inventory', function () {
      say('inventory:' + api.state().products.map(function(p){return p.name;}).join('|'));
    });
    button('Test reload page', function () {location.reload();});
    button('Test hide harness', function () {panel.remove();});
    document.body.appendChild(panel);
    say('harness:ready');
  }
  install();
})();
