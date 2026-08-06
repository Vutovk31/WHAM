# WHAM Quick Replies — Windows acceptance protocol

Target build: `0.10.0-native-test1`

This protocol is the release gate for the first native portable build. Passing GitHub Actions is necessary but does not replace a real Windows desktop test.

## Test environment

Record before testing:

- Windows edition and version;
- x64 architecture;
- antivirus product and database date;
- ZIP file name;
- SHA-256 from the accompanying checksum file;
- SHA-256 recalculated locally;
- whether the test is on a personal or corporate-managed device.

Do not add WHAM to antivirus exclusions. Do not use a corporate-managed computer for the first run.

## Package integrity

The extracted root folder must be named:

`WHAM_Quick_Replies_v0.10.0-native-test1_win-x64`

It must contain exactly:

1. `WHAM Quick Replies.exe`
2. `macros.json`
3. `README-FIRST.txt`
4. `VERSION.txt`

Reject the package if it contains `.cmd`, `.bat`, `.ps1`, `.vbs`, an installer, or an unexpected executable.

Confirm that `VERSION.txt` contains exactly `0.10.0-native-test1`. In **Properties → Details** for the EXE, record product name, file version, product version, description and company.

## Antivirus gate

1. Scan the ZIP before extraction.
2. Scan the extracted folder.
3. Launch only when both scans complete without detection.
4. Record the exact detection name and screenshot if any security product blocks, quarantines or warns about the file.
5. Stop testing after a detection. Do not restore, allow or exclude the file.

A clean scan is evidence only for the tested file, antivirus version and date. It is not a guarantee for other environments.

## Functional acceptance

### A. Startup and tray

1. Launch `WHAM Quick Replies.exe`.
2. Confirm that no console window appears.
3. Confirm that the WHAM tray icon appears.
4. Open the tray menu and confirm that it shows version `0.10.0-native-test1`.
5. Launch the EXE a second time and confirm that only one working instance remains.

### B. Default macro insertion

1. Open Windows Notepad.
2. Focus an empty document.
3. Press `Ctrl+Alt+1` once.
4. Confirm that the expected Unicode text is inserted exactly once.
5. Repeat in a browser text field and one normal desktop application text field.

Record failures separately for: no response, duplicated insertion, corrupted Cyrillic, delayed insertion, wrong focus or hotkey conflict.

### C. Multiline Unicode

Edit one macro in `macros.json` so that it contains:

- at least three lines;
- Cyrillic text;
- digits;
- punctuation;
- the symbols `№`, `₽`, `—` and `«»`.

Use the tray command to reload macros and confirm exact multiline insertion without restarting WHAM.

### D. Validation and recovery

1. Create two macros with the same hotkey and reload.
2. Confirm that WHAM reports the conflict and does not silently register an ambiguous configuration.
3. Restore a valid file.
4. Introduce invalid JSON and restart WHAM.
5. Confirm that a timestamped backup or diagnostic artifact preserves evidence of the invalid file.
6. Restore the valid macro file and confirm normal operation.

### E. Persistence

1. Change macro text.
2. Exit WHAM from the tray.
3. Start it again.
4. Confirm that the changed text is preserved and inserted.
5. Confirm that no unsolicited autostart entry, scheduled task, service, desktop shortcut or system setting was created.

### F. Diagnostics and exit

1. Exit from the tray menu.
2. Confirm that the process terminates.
3. Confirm that registered hotkeys are released and can be used by another application.
4. If `WHAM-errors.log` exists, attach it to the test report; do not include confidential macro contents in a public issue.

## Acceptance decision

The build is accepted for expanded personal testing only when all of the following are true:

- package hash matches;
- archive content and version are correct;
- antivirus scans are clean;
- startup, tray and single-instance behavior pass;
- default and multiline Unicode insertion pass;
- reload, validation, persistence and clean exit pass;
- no system persistence or hidden launcher behavior is created.

Corporate deployment remains blocked until the native build has passed personal testing and an administrator has approved the unsigned executable. Code signing is a separate future release requirement.

## Evidence template

```text
BUILD: 0.10.0-native-test1
ZIP SHA-256 expected:
ZIP SHA-256 calculated:
WINDOWS:
ANTIVIRUS / DATABASE DATE:
PACKAGE CONTENTS: PASS / FAIL
EXE METADATA: PASS / FAIL
ANTIVIRUS ZIP SCAN: PASS / FAIL
ANTIVIRUS EXTRACTED SCAN: PASS / FAIL
STARTUP / TRAY / SINGLE INSTANCE: PASS / FAIL
CTRL+ALT+1 NOTEPAD: PASS / FAIL
OTHER TEXT FIELDS: PASS / FAIL
MULTILINE UNICODE: PASS / FAIL
RELOAD: PASS / FAIL
INVALID CONFIG RECOVERY: PASS / FAIL
PERSISTENCE AFTER RESTART: PASS / FAIL
CLEAN EXIT / HOTKEY RELEASE: PASS / FAIL
UNEXPECTED SYSTEM CHANGES: NONE / DESCRIBE
ERROR LOG ATTACHED: YES / NO / NOT CREATED
DECISION: ACCEPT PERSONAL TEST / REJECT
NOTES:
```
