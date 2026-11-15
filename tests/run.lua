-- FlipSide automated checks. Run from repository root with LuaJIT.
-- All persisted data in these tests is simulated in memory; no KOReader
-- settings, actual SQLite files, user profiles or cloud accounts are opened.
local plugin_dir = os.getenv('FLIPSIDE_PLUGIN_DIR') or 'flipside.koplugin'
package.path = table.concat({
    plugin_dir .. '/?.lua',
    plugin_dir .. '/lib/sync/?.lua',
    plugin_dir .. '/lib/ui/?.lua',
    package.path,
}, ';')

local total, failed = 0, 0
local function test(name, fn)
    total = total + 1
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        io.stderr:write('FAIL ', name, ': ', tostring(err), '\n')
    else
        print('PASS ' .. name)
    end
end
local function check(ok, message)
    if not ok then error(message or 'assertion failed', 2) end
end
local function eq(a, b, name)
    if a ~= b then error((name or 'value') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function raises(fn)
    local ok = pcall(fn)
    check(not ok, 'expected failure for malformed input')
end
local function clone(t)
    if type(t) ~= 'table' then return t end
    local n = {}
    for k,v in pairs(t) do n[clone(k)] = clone(v) end
    return n
end
local function q(word, streak)
    return {word = word, created = 1760000000, streak = streak or 0}
end
local function snap(queue, completed, attempts, correct, missed)
    return {version=1, queue=queue or {}, completed=completed or {},
        attempts=attempts or 0, correct=correct or 0, missed=missed or 0}
end
local SLOT = 'intensive\tall\t'

-- Compile ALL real plugin modules, but do not execute modules that require the
-- KOReader UI or a device. This is a syntax check, not a full UI test.
test('Lua syntax of all 36 modules', function()
    local list = {
      '_meta.lua', 'main.lua', 'flipside_calendar_cloud.lua',
      'flipside_compat.lua', 'flipside_cram_cloud.lua',
      'flipside_cram_store.lua', 'flipside_db.lua',
      'flipside_diagnostics.lua', 'flipside_dictionary_locks.lua',
      'flipside_engine.lua', 'flipside_flashcards.lua',
      'flipside_font_picker.lua', 'flipside_frame_cover.lua',
      'flipside_full_sentence.lua', 'flipside_import.lua',
      'flipside_intensive.lua', 'flipside_learning_audit.lua',
      'flipside_mainmenu_style.lua', 'flipside_meanings_popup.lua',
      'flipside_migrate.lua', 'flipside_popup_header.lua',
      'flipside_rounded_menu.lua', 'flipside_saved_meanings.lua',
      'flipside_sleep_trace.lua', 'flipside_sync.lua',
      'flipside_undo_recovery.lua', 'flipside_virtual_filters.lua',
      'lib/cards/flipside_card_buttons.lua',
      'lib/cards/flipside_card_style_angular.lua',
      'lib/cards/flipside_card_style_circuit.lua',
      'lib/cards/flipside_card_style_classic.lua',
      'lib/sync/flipside_calendar_merge.lua',
      'lib/sync/flipside_cram_merge.lua',
      'lib/sync/flipside_sync_utils.lua',
      'lib/ui/flipside_icon_store.lua',
      'lib/ui/flipside_pager_bounds.lua',
    }
    for _, path in ipairs(list) do
        local f, err = loadfile(plugin_dir .. '/' .. path)
        check(f, path .. ': ' .. tostring(err))
    end
end)

local SyncUtils = dofile(plugin_dir .. '/lib/sync/flipside_sync_utils.lua')
local Cram = dofile(plugin_dir .. '/lib/sync/flipside_cram_merge.lua')
local Calendar = dofile(plugin_dir .. '/lib/sync/flipside_calendar_merge.lua')

test('sync compares nested data ignoring map order', function()
    check(SyncUtils.sameData({a=1,b={x=true,y={1,2}}}, {b={y={1,2},x=true},a=1}))
    check(not SyncUtils.sameData({a=1},{a=2}))
    check(not SyncUtils.sameData({a=1},{a=1,b=2}))
end)
test('sync rejects cyclic data comparison', function()
    local a,b={},{}
    a.self=a; b.self=b
    check(not SyncUtils.sameData(a,b))
end)
test('sync compares actual temporary file contents, not modification time', function()
    local first, second = os.tmpname(), os.tmpname()
    local ok, err = pcall(function()
        local a=assert(io.open(first,'wb')); a:write('alpha');a:close()
        local b=assert(io.open(second,'wb'));b:write('alpha');b:close()
        check(SyncUtils.sameFile(first,second))
        b=assert(io.open(second,'wb'));b:write('omega');b:close()
        check(not SyncUtils.sameFile(first,second))
        check(not SyncUtils.sameFile(first,second .. '.missing'))
    end)
    os.remove(first);os.remove(second)
    check(ok,err)
end)

test('CRAM merge imports remote progress from same baseline', function()
    local base={[SLOT]=snap({q('lantern',0)})}
    local local_map=clone(base)
    local remote={[SLOT]=snap({q('lantern',2)}, {}, 2,2,0)}
    local merged, conflicts=Cram.merge(local_map,remote,base)
    eq(conflicts,0)
    eq(merged[SLOT].queue[1].streak,2)
    eq(merged[SLOT].correct,2)
end)
test('CRAM merge keeps non-overlapping additions from two devices', function()
    local l={[SLOT]=snap({q('apple')})}
    local r={[SLOT]=snap({q('pear')})}
    local m,c=Cram.merge(l,r,{})
    eq(c,0)
    eq(#m[SLOT].queue,2)
    eq(m[SLOT].queue[1].word,'apple')
    eq(m[SLOT].queue[2].word,'pear')
end)
test('CRAM flags concurrent edit of same word', function()
    local base={[SLOT]=snap({q('apple',0)})}
    local l={[SLOT]=snap({q('apple',1)})}
    local r={[SLOT]=snap({q('apple',2)})}
    local m,c=Cram.merge(l,r,base)
    eq(c,1)
    eq(m[SLOT].queue[1].streak,1) -- local checkpoint preserved for conflict handling
end)
test('CRAM counter changes from both devices are combined', function()
    local l={[SLOT]=snap({}, {}, 9,5,4)}
    local r={[SLOT]=snap({}, {}, 8,6,2)}
    local b={[SLOT]=snap({}, {}, 6,3,3)}
    local m,c=Cram.merge(l,r,b)
    eq(c,0)
    eq(m[SLOT].attempts,11)
    eq(m[SLOT].correct,8)
    eq(m[SLOT].missed,4)
end)
test('CRAM rejects invalid snapshot slots and duplicate words', function()
    raises(function() Cram.normalizeSnapshots({['unsafe-key']=snap()}) end)
    raises(function() Cram.normalizeSnapshots({[SLOT]=snap({q('a'),q('a')})}) end)
    raises(function() Cram.normalizeSnapshots({[SLOT]=snap({q('a',-1)})}) end)
end)
test('CRAM merge does not mutate source maps', function()
    local a={[SLOT]=snap({q('lamp',1)})}
    local b={[SLOT]=snap({q('lamp',3)})}
    local aa,bb=clone(a),clone(b)
    Cram.merge(a,b,{[SLOT]=snap({q('lamp',0)})})
    check(SyncUtils.sameData(a,aa))
    check(SyncUtils.sameData(b,bb))
end)
test('CRAM statistics merge combines independent updates', function()
    local base={intensive={correct=5,missed=2}}
    local loc={intensive={correct=7,missed=2}}
    local rem={intensive={correct=5,missed=3}}
    local out=Cram.mergeStats(loc,rem,base)
    eq(out.intensive.correct,7)
    eq(out.intensive.missed,3)
end)

test('calendar records study days by device', function()
    local a=Calendar.updateOwn(Calendar.empty(),'android123',{
        ['2026-11-12']='recorded'
    })
    local b=Calendar.updateOwn(Calendar.empty(),'kindle123',{
        ['2026-11-13']='estimated_legacy'
    })
    local merged=Calendar.merge(a,b)
    eq(merged.nodes.android123.revision,1)
    eq(merged.nodes.kindle123.revision,1)
    local remote=Calendar.remoteDays(merged,'android123')
    check(remote['2026-11-12']==nil)
    eq(remote['2026-11-13'],'estimated_legacy')
end)
test('calendar revision increases only when data changes', function()
    local first=Calendar.updateOwn(Calendar.empty(),'android123',{
        ['2026-11-12']='recorded'
    })
    local same=Calendar.updateOwn(first,'android123',{
        ['2026-11-12']='recorded'
    })
    eq(same.nodes.android123.revision,1)
    local changed=Calendar.updateOwn(same,'android123',{
        ['2026-11-13']='recorded'
    })
    eq(changed.nodes.android123.revision,2)
    check(changed.nodes.android123.days['2026-11-12']==nil)
end)
test('calendar rejects conflicting same-revision device updates', function()
    local a=Calendar.updateOwn(Calendar.empty(),'android123',{['2026-11-12']='recorded'})
    local b=Calendar.updateOwn(Calendar.empty(),'android123',{['2026-11-13']='recorded'})
    raises(function() Calendar.merge(a,b) end)
end)
test('calendar rejects impossible dates', function()
    raises(function() Calendar.normalizeDays({['2026-02-30']='recorded'}) end)
    raises(function() Calendar.normalizeDays({['2026-11-10']='wrong'}) end)
end)

-- Fake LuaSettings and LFS: nothing ever writes outside this Lua process.
local fake_disk = {}
local fail_flush = false
local diag_events = {}
local root = '/virtual/flipside-tests-only'
local function fake_open(file)
    local writes = {}
    return {
        readSetting=function(_,k)
            return clone(fake_disk[file] and fake_disk[file][k])
        end,
        saveSetting=function(_,k,v) writes[k]=clone(v) end,
        flush=function()
            if fail_flush then error('simulated failure before persisted write') end
            local new = clone(fake_disk[file] or {})
            for k,v in pairs(writes) do new[k]=clone(v) end
            fake_disk[file]=new
        end,
    }
end
package.loaded['luasettings'] = {open=function(_,file) return fake_open(file) end}
package.loaded['datastorage'] = {getSettingsDir=function() return root end}
package.loaded['util'] = {makePath=function(_) return true end}
package.loaded['libs/libkoreader-lfs'] = {
    attributes=function(path,attr)
        if fake_disk[path] then return attr=='mode' and 'file' or {mode='file'} end
        return nil
    end
}
package.loaded['flipside_diagnostics'] = {
    inspectCramSnapshots=function() end,
    report=function(...) diag_events[#diag_events+1]={...} end,
}
local Store = dofile(plugin_dir .. '/flipside_cram_store.lua')
local Recovery = dofile(plugin_dir .. '/flipside_undo_recovery.lua')
local function fresh()
    fake_disk={}
    fail_flush=false
    diag_events={}
end

test('official miss enters both CRAM modes and Undo removes it', function()
    fresh()
    local s=Store.open()
    local filters={{kind='all'}}
    local old=s:recordOfficialMiss({word='orchard',created=1760000000}, filters)
    local a=Store.key('intensive',filters[1])
    local b=Store.key('ultra',filters[1])
    eq(#s.snapshots[a].queue,1)
    eq(#s.snapshots[b].queue,1)
    eq(s.snapshots[a].queue[1].word,'orchard')
    s:undoOfficialMiss('orchard',old)
    eq(#s.snapshots[a].queue,0)
    eq(#s.snapshots[b].queue,0)
end)
test('removing a CRAM word clears both mode checkpoints', function()
    fresh()
    local s=Store.open()
    local a=Store.key('intensive',{kind='all'})
    local b=Store.key('ultra',{kind='all'})
    s:put(a,snap({q('deleted'),q('kept')}))
    s:put(b,snap({},{{word='deleted',created=1760000000}}))
    check(s:removeWord('deleted'))
    eq(#s.snapshots[a].queue,1)
    eq(s.snapshots[a].queue[1].word,'kept')
    eq(#s.snapshots[b].completed,0)
    check(not s:removeWord('deleted'))
end)
test('CRAM checkpoint is durable across reopen', function()
    fresh()
    local s=Store.open()
    local key=Store.key('intensive',{kind='all'})
    s:put(key,snap({q('berry')}))
    local reloaded=Store.open()
    eq(reloaded.snapshots[key].queue[1].word,'berry')
    eq(reloaded.sequence,s.sequence)
end)
test('failed CRAM flush preserves last acknowledged checkpoint', function()
    fresh()
    local s=Store.open()
    local key=Store.key('intensive',{kind='all'})
    s:put(key,snap({q('initial')}))
    local before=clone(s.snapshots)
    local seq=s.sequence
    fail_flush=true
    raises(function() s:put(key,snap({q('newer')})) end)
    check(SyncUtils.sameData(before,s.snapshots))
    eq(s.sequence,seq)
end)
test('CRAM reset refuses unverified empty deck', function()
    fresh()
    raises(function() Store.resetAfterVerifiedEmptyDeck(false) end)
    raises(function() Store.resetAfterVerifiedEmptyDeck(nil) end)
end)
test('Undo recovery journal is idempotent and persistent', function()
    fresh()
    local journal=Recovery.open()
    journal:add('word',1760000000)
    journal:add('word',1760000000)
    eq(#journal.pending,1)
    local reopened=Recovery.open()
    eq(#reopened.pending,1)
    eq(reopened.pending[1].word,'word')
end)
test('Undo recovery keeps failed events and removes successful ones', function()
    fresh()
    local r=Recovery.open()
    r:add('one',1760000000)
    r:add('two',1760000001)
    local ok,failed_count=r:replay(function(w) return w=='one' end)
    eq(ok,1)
    eq(failed_count,1)
    eq(#r.pending,1)
    eq(r.pending[1].word,'two')
    eq(#diag_events,1)
    local done,fails=r:replay(function() return true end)
    eq(done,1)
    eq(fails,0)
    eq(#r.pending,0)
end)
test('Undo journal failed write does not pretend the event was saved', function()
    fresh()
    local r=Recovery.open()
    fail_flush=true
    raises(function() r:add('one',1760000000) end)
    eq(#r.pending,0)
    eq(r.sequence,0)
end)

-- DPI-safe menu footer. Test the actual sizing helper with mocked KOReader
-- device/Size API; no UI is drawn and no state is persisted.
local screen={dpi=1,width=800}
function screen:getWidth() return self.width end
function screen:scaleBySize(n) return math.floor(n*self.dpi + 0.5) end
package.loaded['device']={screen=screen}
package.loaded['ui/size']={padding={button=4}}
local Pager = dofile(plugin_dir .. '/lib/ui/flipside_pager_bounds.lua')
local function fake_button()
    return {
        icon_width=52, icon_height=52,padding_h=4,margin=0,bordersize=0,
        label_widget={free=function() end},
        getSize=function(self) return {w=self.icon_width+2*self.padding_h} end,
        init=function() end,
    }
end
local function fake_menu(width,label_width)
    return {
        inner_dimen={w=width},
        page_info_spacer={width=32},
        page_info_text={getSize=function() return {w=label_width} end},
        page_info={resetLayout=function(self) self.calls=(self.calls or 0)+1 end},
        page_info_first_chev=fake_button(),page_info_left_chev=fake_button(),
        page_info_right_chev=fake_button(),page_info_last_chev=fake_button(),
    }
end
local function check_fit(menu)
    local total_width=menu.page_info_text:getSize().w+4*menu.page_info_spacer.width
    for _,btn in ipairs({menu.page_info_first_chev,menu.page_info_left_chev,
        menu.page_info_right_chev,menu.page_info_last_chev}) do
        total_width=total_width+btn:getSize().w
    end
    check(total_width<=menu.inner_dimen.w, 'pager exceeds available panel width')
    check(menu.page_info.calls>0, 'layout was not reset')
end
test('pager fits both normal and high DPI', function()
    screen.dpi=1
    local normal=fake_menu(800,145)
    Pager.fit(normal)
    check_fit(normal)
    screen.dpi=4
    local high=fake_menu(400,120)
    Pager.fit(high)
    check_fit(high)
end)
test('pager can recover original icon size after expanding screen', function()
    screen.dpi=4
    local m=fake_menu(400,120)
    Pager.fit(m)
    local before=m.page_info_first_chev.icon_width
    m.inner_dimen.w=1000
    screen.dpi=1
    Pager.fit(m)
    eq(m.page_info_first_chev.icon_width,52)
    check(m.page_info_first_chev.icon_width>=before)
    check_fit(m)
end)

print(string.format('\n%d tests, %d failed',total,failed))
if failed>0 then os.exit(1) end
