# WHAM — Work Helper & Automation Manager

WHAM is a local Windows productivity utility.

## Release priority

The first working release is **Quick Replies v0.1**.

Initial scope:

- global hotkeys `Ctrl+Alt+1` … `Ctrl+Alt+5`;
- five configurable reply templates;
- template variables;
- preview before insertion when variables are required;
- insertion into the previously active application;
- local-only storage;
- no administrator rights required for normal use.

Default templates:

1. `Заказ в работе`;
2. `Заявка принята`;
3. `Не хватает данных`;
4. `Уточните договор`;
5. `Принял в обработку`.

## Planned second module

**Capture & OCR** will follow after the shared Windows shell, settings storage, logging and release pipeline are stable.

## Target platform

- Windows 10/11 x64;
- .NET 8 Desktop;
- WPF;
- portable ZIP for the first internal release;
- MSIX/installer and code signing after MVP validation.

## Current status

Repository initialized on 2026-08-02. The next milestone is a buildable Quick Replies application and a Windows CI artifact.
