'use strict';
const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('dylib/feats/steaminstall.js', 'utf8');
const command = {id:'11111111-1111-4111-8111-111111111111', appid:42, steamid:'76561198123456789', tool:'', operation:'install'};
async function scenario(options = {}) {
    const statuses = [], calls = [];
    let state = 0, licenses = options.licenses || [];
    const ctx = vm.createContext({
        Uint8Array, TextDecoder, TextEncoder, JSON, Error, Date,
        window:{__cartoucheInstallUI:options.unpatched ? 0 : 1},
        setInterval:() => {}, setTimeout: (fn, ms) => { if (ms < 8000 || options.timeout) fn(); },
        open:async() => true, tok:async() => 'token',
        collect:() => ({steamid:command.steamid, apps:options.unowned ? [] : [{appid:42}]}),
        f2:(n,b) => new TextEncoder().encode(b),
        call:async (name, bytes) => {
            if (name.includes('GetInstallCommand')) {
                const json = new TextEncoder().encode(JSON.stringify({...command, ...options.command}));
                const length = []; let n = json.length;
                do { let b = n & 127; n >>>= 7; if(n) b |= 128; length.push(b); } while(n);
                return {er:1, body:new Uint8Array([10,...length,...json])};
            }
            statuses.push(JSON.parse(new TextDecoder().decode(bytes).split('\n').slice(1).join('\n')));
            return {er:1};
        },
        SteamClient:{
            Apps:{SpecifyCompatTool:async() => calls.push('tool'), LoadEula:async() => licenses,
                MarkEulaAccepted:async() => calls.push('accepted'), PauseAppUpdate:async() => calls.push('paused')},
            Installs:{
                GetInstallManagerInfo:async() => options.timeout ? new Promise(() => {}) : ({eInstallState:state,rgApps:state ? [{nAppID:42}] : []}),
                OpenInstallWizard:async() => {
                    calls.push('install');state=1;
                    assert.equal(ctx.window.__cartoucheInstallOwns({rgApps:[{nAppID:42}]}),true);
                    assert.equal(ctx.window.__cartoucheInstallOwns({rgApps:[{nAppID:43}]}),false);
                    assert.equal(ctx.window.__cartoucheInstallOwns({rgApps:[{nAppID:42},{nAppID:43}]}),false);
                },
                SetCreateShortcuts:async() => {},
                ContinueInstall:async() => {state=licenses.length && !calls.includes('accepted') ? 8 : 0;},
                CancelInstall:async() => {state=0;calls.push('cancel');}
            }
        }
    });
    vm.runInContext(source,ctx);
    await vm.runInContext('installTick()',ctx);
    await vm.runInContext('installTick()',ctx);
    return {statuses,calls,ctx};
}
if (process.argv[2]) {
    const guard = fs.readFileSync(process.argv[2], 'utf8');
    let callback;
    const shown = [], handles = [];
    const context = vm.createContext({window:{}, SteamClient:{Installs:{
        RegisterForShowInstallWizard:fn => {callback=fn;return 'handle';}
    }}, owner:{m_clientHandles:{Add:h => handles.push(h)}, OnShowInstallWizard:info => shown.push(info)}});
    vm.runInContext(`(function(){${guard}}).call(owner)`, context);
    assert.equal(context.window.__cartoucheInstallUI,1);
    assert.deepEqual(handles,['handle']);
    context.window.__cartoucheInstallOwns = info => info.currentAppID === 42;
    callback({currentAppID:42,eInstallState:8});
    callback({currentAppID:43,eInstallState:8});
    callback({eInstallState:0});
    assert.deepEqual(shown,[{currentAppID:43,eInstallState:8},{eInstallState:0}]);
    console.log('Steam install UI: owned wizard suppressed, other installs and completion preserved');
}
(async() => {
    let r=await scenario();
    assert.deepEqual(r.calls,['tool','install']);
    assert.equal(r.statuses.at(-1).state,'queued');
    assert.equal(r.ctx.window.__cartoucheInstallOwns({currentAppID:42}),false);
    r=await scenario({unpatched:true});assert.deepEqual(r.calls,[]);assert.equal(r.statuses.at(-1).message,'integration-update-required');
    r=await scenario({unowned:true});assert.equal(r.calls.length,0);
    r=await scenario({command:{handled:true}});assert.equal(r.calls.length,0);
    r=await scenario({licenses:[{id:1,version:2,url:'https://store.steampowered.com/eula/42'}]});
    assert.equal(r.statuses.at(-1).state,'license');assert(!r.calls.includes('accepted'));
    r=await scenario({command:{operation:'cancel'}});assert(r.calls.includes('paused'));
    r=await scenario({timeout:true});assert.equal(r.statuses.at(-1).state,'failed');assert.equal(r.statuses.at(-1).message,'steam-timeout');
    console.log('Steam install: queued once, owned-account gate, restart deduplication, explicit EULA, cancel passed');
})().catch(error=>{console.error(error);process.exit(1);});
