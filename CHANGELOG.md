# Changelog

## [0.4.0] - 2026-09-08

### Added

- **Update checking** — once a day (configurable) the plugin asks GitHub for
  the latest release. A newer version raises one notification and shows a
  banner in the popup: `↑ Update available  0.3.0 → 0.4.0`.
- **One-click update** — when the plugin is a plain `git` checkout, the
  banner's **Update** button runs `git fetch --tags && git checkout <tag>`
  (only if the working tree is clean), then prompts you to
  `omarchy restart shell`. Linked dev checkouts and non-git copies are left
  alone with a note instead.
- New `print-center check-update` / `self-update` subcommands; settings
  `checkUpdates`, `updateCheckHours`.

## [0.3.0] - 2026-09-08

First public release.

### Printing

- **Bar pill** — the tracked printer's state and the queued-job count. Turns
  the theme accent on a warning (paper low, ink low, paused) and urgent on an
  error (out of paper, jam, offline) or when the CUPS service is down.
- **Printers** — each configured printer with state, default marker, make and
  model, and ink / supply levels. Levels come from CUPS, or straight from the
  device over IPP (`ipptool`) when the queue carries none yet. Per printer:
  **Set default** (per-user, no password), **Test page**, and an **Options**
  expander for the default paper size, tray, paper type, quality, colour and
  two-sided setting (also per-user).
- **Queue** — active jobs with **Hold / Release** and **Cancel**, plus
  **Clear the whole queue**.
- **Add a network printer** — scans with `driverless` + `avahi-browse` and
  adds the chosen one as a driverless IPP Everywhere queue. The only action
  that asks for a password (`pkexec lpadmin`).
- **Printer settings** link to `system-config-printer`.
- **Headless service** — polls the queue and raises a desktop notification
  when a job finishes, a job is held, or a printer errors. The `done`,
  `error` and `held` classes toggle independently.

### Scanning

- **Scan tab** — finds SANE scanners (driverless eSCL / WSD via
  `sane-airscan`, plus USB), pick mode / resolution / source, scan to PDF,
  PNG or JPEG in `~/Pictures/Scans`. ADF batches become one PDF. Live
  progress bar, image preview, Open / Folder / Scan another.
- Detects whether `sane` / `sane-airscan` / `img2pdf` are installed and
  offers a one-click install (opens a terminal for the sudo prompt).

### Under the hood

- All CUPS / SANE access is in one Node CLI (`bin/print-center`); the bar
  widget and the service both shell out to it. Parsing is pure and
  unit-tested (42 tests); system calls are isolated in `lib/io.mjs`.
- Requires Node.js (`omarchy pkg add nodejs`); the popup says so if missing.
- Everything else for printing ships with Omarchy.
