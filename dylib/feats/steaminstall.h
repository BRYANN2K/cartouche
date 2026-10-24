// Generated from steaminstall.js by dylib/tests/embed-steaminstall.py.
#define NP_STEAM_INSTALL \
    "let installSeen = '', installBusy = false, installLogged = false, installWarned = false;" \
    "console.info('Cartouche: install worker ready');" \
    "let installOwner;" \
    "window.__cartoucheInstallOwns = manager => !!installOwner && Date.now() < installOwner.until &&" \
    "    (manager.currentAppID === installOwner.appid ||" \
    "        (manager.rgApps?.length === 1 && manager.rgApps[0].nAppID === installOwner.appid));" \
    "const installLease = command => { installOwner = {appid:command.appid, until:Date.now()+300000}; };" \
    "" \
    "const installWait = promise => Promise.race([Promise.resolve(promise), new Promise((_, reject) => setTimeout(() => reject(Error('steam-timeout')), 8000))]);" \
    "const installPayload = bytes => {" \
    "    let p = 1, n = 0, shift = 0, b;" \
    "    do { b = bytes[p++]; n += (b & 127) * 2 ** shift; shift += 7; } while (b & 128 && shift < 32);" \
    "    return JSON.parse(new TextDecoder().decode(bytes.slice(p, p + n)));" \
    "};" \
    "const installStatus = async (command, state, extra = {}) => {" \
    "    const token = await tok();" \
    "    if (!token) throw Error('transport');" \
    "    const json = JSON.stringify({id:command.id, appid:command.appid, state, fraction:0, ...extra});" \
    "    const r = await call('Cartouche.ExportInstallStatus#1', new Uint8Array(f2(1, token + '\\n' + json)));" \
    "    if (r.er !== 1) throw Error('status');" \
    "};" \
    "const installTick = async () => {" \
    "    if (installBusy || !await open()) return;" \
    "    installBusy = true;" \
    "    let command;" \
    "    try {" \
    "        const reply = await call('Cartouche.GetInstallCommand#1', new Uint8Array(0));" \
    "        if (!installLogged) { console.info('Cartouche: install transport ' + reply.er + ', response bytes ' + (reply.body?.length || 0)); installLogged = true; }" \
    "        if (reply.er !== 1) return;" \
    "        command = installPayload(reply.body);" \
    "        if (!command.id || command.id === installSeen) return;" \
    "        const owned = collect();" \
    "        if (!owned || owned.steamid !== command.steamid || !owned.apps.some(a => a.appid === command.appid)) return;" \
    "        console.info('Cartouche: install request for app ' + command.appid + ', ' + command.operation);" \
    "        installSeen = command.id;" \
    "        if (command.handled) return;" \
    "        await installStatus(command, 'preparing');" \
    "        const pause = ms => new Promise(resolve => setTimeout(resolve, ms));" \
    "        const info = () => installWait(SteamClient.Installs.GetInstallManagerInfo());" \
    "        const ours = manager => manager.rgApps?.some(a => a.nAppID === command.appid);" \
    "        if (command.operation === 'cancel') {" \
    "            const manager = await info();" \
    "            if (ours(manager)) await installWait(SteamClient.Installs.CancelInstall());" \
    "            await installWait(SteamClient.Apps.PauseAppUpdate(command.appid));" \
    "            installOwner = undefined;" \
    "            await installStatus(command, 'cancelled');" \
    "            return;" \
    "        }" \
    "        if (!window.__cartoucheInstallUI) throw Error('integration-update-required');" \
    "        if (command.operation === 'accept') {" \
    "            installLease(command);" \
    "            const manager = await info();" \
    "            if (!ours(manager) || manager.eInstallState !== 8) throw Error('license-expired');" \
    "            const licenses = await installWait(SteamClient.Apps.LoadEula(command.appid));" \
    "            const expected = command.licenses || [];" \
    "            if (JSON.stringify(licenses.map(e => [e.id,e.version,e.url])) !== JSON.stringify(expected.map(e => [e.id,e.version,e.url]))) throw Error('license-changed');" \
    "            for (const e of licenses) await installWait(SteamClient.Apps.MarkEulaAccepted(command.appid, e.id, e.version));" \
    "        } else {" \
    "            const current = await info();" \
    "            if (current.eInstallState !== 0) throw Error('another-install');" \
    "            await installWait(SteamClient.Apps.SpecifyCompatTool(command.appid, command.tool || '', 0));" \
    "            installLease(command);" \
    "            await installWait(SteamClient.Installs.OpenInstallWizard([command.appid], '0'));" \
    "            let manager;" \
    "            for (let i = 0; i < 20; i++) {" \
    "                await pause(250); manager = await info();" \
    "                if (ours(manager)) break;" \
    "            }" \
    "            if (!ours(manager)) throw Error('install-unavailable');" \
    "            if (command.destination) {" \
    "                let folders = await installWait(SteamClient.InstallFolder.GetInstallFolders());" \
    "                let folder = folders.find(f => f.strFolderPath === command.destination);" \
    "                if (!folder) {" \
    "                    await installWait(SteamClient.InstallFolder.AddInstallFolder(command.destination));" \
    "                    folders = await installWait(SteamClient.InstallFolder.GetInstallFolders());" \
    "                    folder = folders.find(f => f.strFolderPath === command.destination);" \
    "                }" \
    "                if (!folder) throw Error('install-folder');" \
    "                await installWait(SteamClient.Installs.SetInstallFolder(folder.nFolderIndex));" \
    "            }" \
    "            await installWait(SteamClient.Installs.SetCreateShortcuts(false, false));" \
    "        }" \
    "        for (let i = 0; i < 30; i++) {" \
    "            const manager = await info();" \
    "            if (manager.eAppError) throw Error('steam-' + manager.eAppError);" \
    "            if (manager.eInstallState === 0) {" \
    "                installOwner = undefined;" \
    "                await installStatus(command, 'queued');" \
    "                return;" \
    "            }" \
    "            if (!ours(manager)) throw Error('another-install');" \
    "            if (manager.eInstallState === 8) {" \
    "                const licenses = await installWait(SteamClient.Apps.LoadEula(command.appid));" \
    "                await installStatus(command, 'license', {licenses: licenses.map(e => ({id:e.id,version:e.version,url:e.url}))});" \
    "                return;" \
    "            }" \
    "            await installWait(SteamClient.Installs.ContinueInstall());" \
    "            await pause(500);" \
    "        }" \
    "        throw Error('install-timeout');" \
    "    } catch (error) {" \
    "        installOwner = undefined;" \
    "        if (!installWarned) { console.warn('Cartouche: install worker ' + String(error.message || error)); installWarned = true; }" \
    "        if (command?.id) await installStatus(command, 'failed', {message:String(error.message || error).slice(0,160)}).catch(() => {});" \
    "    } finally { installBusy = false; }" \
    "};" \
    "setInterval(() => { installTick().catch(() => {}); }, 2000);" \
    ""
