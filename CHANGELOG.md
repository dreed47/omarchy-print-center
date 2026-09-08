# Changelog

## [0.1.0] - 2026-09-08

First release. Phase 1: printing management, no new dependencies.

### Added

- **Bar pill** showing the tracked printer's state and the queued-job count.
  Turns the theme accent on a warning (paper low, ink low, paused) and urgent
  on an error (out of paper, jam, offline) or when CUPS is not running.
- **Popup**:
  - Printer list with state, default marker, make/model, and ink / supply
    levels read from `lpoptions`.
  - Per-printer **Set default** (per-user, no password) and **Test page**.
  - Active **queue** with per-job **Hold / Release** and **Cancel**, plus
    **Clear the whole queue**.
  - **Add a network printer** — scans with `driverless` + `avahi-browse` and
    adds the chosen one as a driverless IPP Everywhere queue. This is the only
    action that asks for a password (`pkexec lpadmin`).
  - **Printer settings** link to `system-config-printer`.
- **Headless service** polling `print-center status --json` and raising a
  desktop notification when a job finishes, a job is held, or a printer
  reports an error. Event classes (`done`, `error`, `held`) are individually
  toggleable.
- **`print-center` CLI** — the single engine the widget and service both call:
  `status`, `printers`, `jobs`, `cancel`, `hold`, `release`, `reprint`,
  `default`, `testpage`, `discover`, `add`, `open-settings`.

### Notes

- Uses only CUPS tooling Omarchy already ships (`lpstat`, `lp`, `lpoptions`,
  `lpadmin`, `lpinfo`, `driverless`) plus `avahi-browse` and `pkexec`.
- Requires Node.js (`omarchy pkg add nodejs`); the popup says so if it is
  missing.
- Scanning (SANE) is planned for a later release and is **not** in 0.1.0.
