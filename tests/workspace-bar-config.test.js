const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(require.resolve('../WorkspaceBarConfig.js'), 'utf8'), context);
const migrate = context.removeDuplicateNativeWidget;
const native = 'omarchy.workspaces';
const overview = 'hancore.overview-workspaces';

test('declares native replacement for install and disable lifecycle', () => {
    assert.equal(require('../manifest.json').omarchy.clonedFrom, native);
});

test('upgrades duplicates across sections while preserving settings and other widgets', () => {
    const config = { bar: { layout: {
        left: [{ id: 'omarchy.menu' }, { id: native }],
        center: [{ id: overview, sortMode: 'system', perMonitor: false }],
        right: [native, { id: 'omarchy.clock', format: 'HH:mm' }]
    } }, plugins: ['unrelated'], disabled: ['unrelated'] };
    assert.equal(migrate(config), true);
    assert.deepEqual(config, { bar: { layout: {
        left: [{ id: 'omarchy.menu' }],
        center: [{ id: overview, sortMode: 'system', perMonitor: false }],
        right: [{ id: 'omarchy.clock', format: 'HH:mm' }]
    } }, plugins: ['unrelated'], disabled: ['unrelated'] });
    assert.equal(migrate(config), false);
});

test('leaves native workspaces alone when Overview is not in the bar', () => {
    for (const config of [{}, { plugins: [overview], bar: { layout: { left: [native] } } }]) {
        const before = JSON.stringify(config);
        assert.equal(migrate(config), false);
        assert.equal(JSON.stringify(config), before);
    }
});

test('accepts string entries and missing sections', () => {
    const config = { bar: { layout: { left: [native, overview] } } };
    assert.equal(migrate(config), true);
    assert.deepEqual(config.bar.layout.left, [overview]);
    assert.equal(migrate(config), false);
});
