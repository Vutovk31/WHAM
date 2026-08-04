import fs from 'node:fs';
import assert from 'node:assert/strict';

const macrosPath = new URL('../macros.json', import.meta.url);
const rawMacros = fs.readFileSync(macrosPath, 'utf8').replace(/^\uFEFF/, '');
const macros = JSON.parse(rawMacros);

assert.ok(Array.isArray(macros), 'macros.json must contain an array');
assert.ok(macros.length > 0, 'At least one starter macro is required');

const ids = new Set();
const hotkeys = new Set();
for (const macro of macros) {
  for (const key of ['id', 'title', 'hotkey', 'text']) {
    assert.equal(typeof macro[key], 'string', `${key} must be a string`);
    assert.ok(macro[key].trim().length > 0, `${key} must not be empty`);
  }

  const normalizedId = macro.id.trim();
  const normalizedHotkey = macro.hotkey.replace(/\s/g, '').toUpperCase();
  assert.ok(!ids.has(normalizedId), `Duplicate macro id: ${normalizedId}`);
  assert.ok(!hotkeys.has(normalizedHotkey), `Duplicate hotkey: ${normalizedHotkey}`);
  ids.add(normalizedId);
  hotkeys.add(normalizedHotkey);
}

const expectedStarterHotkeys = [1, 2, 3, 4, 5].map((number) => `CTRL+ALT+${number}`);
assert.deepEqual([...hotkeys].sort(), expectedStarterHotkeys, 'Starter hotkeys must be Ctrl+Alt+1 through Ctrl+Alt+5');

const script = fs.readFileSync(new URL('../WHAM.QuickReplies.ps1', import.meta.url), 'utf8').replace(/^\uFEFF/, '');
for (const contract of [
  '[switch]$SelfTest',
  'function Read-Macros',
  'function Save-Macros',
  'function Backup-File',
  'function Get-Binding',
  'function Register-All',
  'function Set-ClipboardText',
  'function Paste-Text',
  'System.Threading.Mutex',
  'RegisterHotKey',
  '0x4000',
  'WHAM-errors.log',
  'WHAM-status.txt',
  'WHAM self-test passed.',
]) {
  assert.ok(script.includes(contract), `Missing minimal beta contract: ${contract}`);
}

assert.ok(!script.includes('function Register-All([WhamWindow]$Host'), 'Protected PowerShell variable $Host must not be used as a parameter');

const selfTestStart = script.indexOf('function Run-SelfTest');
const appStart = script.indexOf('function Run-App');
assert.ok(selfTestStart >= 0 && appStart > selfTestStart, 'Self-test block is missing');
const selfTestBlock = script.slice(selfTestStart, appStart);
assert.ok(!selfTestBlock.includes('.RegisterBinding('), 'Self-test must not register a real global hotkey');

console.log('Minimal WHAM beta contracts passed.');
