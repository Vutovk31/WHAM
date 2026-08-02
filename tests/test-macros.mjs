import fs from 'node:fs';
import assert from 'node:assert/strict';

const macros = JSON.parse(fs.readFileSync(new URL('../macros.json', import.meta.url), 'utf8'));
assert.equal(macros.length, 5);

const hotkeys = macros.map(({ hotkey }) => hotkey.toUpperCase());
assert.equal(new Set(hotkeys).size, hotkeys.length);
assert.deepEqual([...hotkeys].sort(), [1, 2, 3, 4, 5].map((n) => `CTRL+ALT+${n}`));

const variablePattern = /\{(?<name>[\p{L}_][\p{L}\p{N}_]*)\}/gu;
for (const macro of macros) {
  for (const key of ['id', 'title', 'hotkey', 'text']) assert.equal(typeof macro[key], 'string');
  const variables = [...macro.text.matchAll(variablePattern)].map((match) => match.groups.name);
  assert.ok(variables.length > 0, `${macro.id} should contain a variable`);
  assert.equal(new Set(variables).size, variables.length, `${macro.id} should not repeat variable fields`);
}

console.log('Macro and variable contract validation passed.');

const script = fs.readFileSync(new URL('../WHAM.QuickReplies.ps1', import.meta.url), 'utf8');
for (const contract of [
  'GetDataObject()',
  'Invoke-SafePaste',
  'GetText() -cne $ExpectedText',
  'SetDataObject($Snapshot, $true)',
  'clipboardRestoreTimers',
]) {
  assert.ok(script.includes(contract), `Missing safe clipboard contract: ${contract}`);
}

console.log('Safe clipboard contract validation passed.');
