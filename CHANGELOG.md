# Changelog

## [0.4.3] - 2026-09-22

### Fixed

- **Notification spam from the new zero-page alert added in 0.4.2.**
  `Service.qml`'s notification dedup tracked which alerts a printer "had
  last poll" using raw `printer-state-reasons` codes only. The new
  `zero-page-job` alert isn't a state-reason at all (it comes from
  `page_log`), so it could never appear in that tracked list — meaning it
  looked "new" on every single poll and fired a fresh notification
  roughly every `pollSeconds` (default 20s) for as long as the underlying
  job stayed in CUPS's completed-job history. Fixed to track by each
  printer's actual alert *codes* (`p.alerts`, the superset that already
  includes state-reason alerts) instead of raw state-reasons directly, so
  any alert type — this one and any future one — is correctly remembered
  and only notified once per new occurrence.

## [0.4.2] - 2026-09-22

### Added

- **Detect silent zero-page print failures.** A job can complete in CUPS's
  queue — no error, no lingering printer-state-reason — while the printer
  never actually prints anything. This is easy to hit right now on
  Arch-based distros (Omarchy included): a `libcupsfilters 2.2.x`
  regression ([OpenPrinting/libcupsfilters#246](https://github.com/OpenPrinting/libcupsfilters/issues/246))
  crashes the `pdftopdf` filter on PDFs with certain link/form
  annotations — common output from browsers like Chrome — and CUPS's own
  `printer-state-message` explaining why clears again within seconds,
  well before the next poll. Until now this looked identical to a real
  successful print, with no way to tell from the popup.
  Print Center now cross-checks each recently-completed job against
  CUPS's own `page_log` (world-readable, no elevation needed) and flags
  any job that completed with 0 actual pages printed, right on the
  printer's card and in the bar pill. Written generically — it isn't
  keyed to that one bug, so it also catches any other cause of a silent
  zero-page completion.
- New pure helpers: `parsePageLogTotals`, `zeroPageAlerts` (`printLogic.mjs`);
  new `io.readPageLogTail()`.

## [0.4.1] - 2026-09-08

### Changed

- **Removed the self-updater** (the banner's *Update* button and the
  `self-update` subcommand) at marketplace security review: checking out a
  moving GitHub tag into the live plugin directory isn't bound to reviewed
  bytes. The update **check** stays — the popup still shows a banner and
  links to the release when a newer tag exists; you update by whatever
  method you installed with.
- No more `git fetch` / `git checkout` / install-kind detection in the
  plugin.

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
