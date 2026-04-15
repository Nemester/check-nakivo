# Nakivo Monitoring Plugins (Nagios / Icinga)

<p align="center">
  <img src="https://img.shields.io/badge/License-MIT-blueviolet?style=for-the-badge" alt="License: MIT">
  <img src="https://img.shields.io/badge/Built%20by-NEMESTER-DARKGREEN?style=for-the-badge" alt="Built by Nous Research"></a>
</p>

This repository provides a set of Bash-based monitoring plugins for [Nakivo Backup & Replication](https://www.nakivo.com/), designed for use with Nagios, Icinga, and NRPE.

The plugins use the Nakivo CLI to retrieve system information and evaluate the health and status of key components.

---

## Table of Contents

- [Included Checks](#included-checks)
- [Requirements](#requirements)
- [Installation](#installation)
- [NRPE Integration](#nrpe-integration)
- [Usage](#usage)
  - [Repository Check](#repository-check)
  - [Jobs Check](#jobs-check)
  - [Transporter Check](#transporter-check)
- [Threshold Semantics](#threshold-semantics)
- [Example Outputs](#example-outputs)
  - [Repository Check](#repository-check-1)
  - [Jobs Check](#jobs-check-1)
  - [Transporter Check](#transporter-check-1)
- [Return Codes](#return-codes)
- [Notes and Limitations](#notes-and-limitations)
- [License](#license)

---


## Included Checks
| Script | Description | Monitored Values | Thresholds | Perfdata | Logic |
|--------|------------|------------------|------------|----------|--------|
| **check_nakivoRepoState.sh** | Checks the state and capacity of a specific Nakivo repository | - Attached state<br>- Accessibility<br>- Number of backups<br>- Free space<br>- Allocated space<br>- Reclaimable space | - Free space<br>- Reclaimable space<br>- Allocated space | - Backups<br>- Free space<br>- Allocated space<br>- Reclaimable space | n/a |
| **check_nakivoJobs.sh** | Checks all Nakivo jobs and evaluates their last execution result | - Job state<br>- Last execution result | n/a | n/a | - All successful → OK<br>- Not executed → WARNING<br>- Failed/other → CRITICAL |
| **check_nakivoTransporterState.sh** | Checks the state of a specific Nakivo transporter | - Transporter state<br>- Transporter status<br>- Current load<br>- Maximum load | - Load (higher is worse) | - Load | n/a |

---

## Requirements

- Nakivo Director with CLI available:
  /opt/nakivo/director/bin/cli.sh

- Linux system with:
  - `bash`
  - `awk`
  - `grep`
  - `sed`
  - `tr`

- Nagios / Icinga (or compatible monitoring system)
- NRPE (for remote execution)

---

## Installation

1. Copy scripts to your plugins directory:
   `/usr/lib/nagios/plugins/`

2. Set executable permissions:
   `chmod 755 check_nakivo*.sh`

3. Create configuration file:
   `/etc/nagios/nakivo.conf`

Example:
```text
NAKIVO_USER="monitoring_user"
NAKIVO_PASS="supersecret"
NAKIVO_HOST="localhost"
NAKIVO_PORT="4443"
```
4. Secure the configuration file:
   `chmod 600 /etc/nagios/nakivo.conf`

---

## NRPE Integration

Example `/etc/nagios/nrpe.cfg`:
```text

command[check_nakivoJobs]=/usr/lib/nagios/plugins/check_nakivoJobs.sh
command[check_nakivoRepoState]=/usr/lib/nagios/plugins/check_nakivoRepoState.sh $ARG1$
command[check_nakivoTransporter]=/usr/lib/nagios/plugins/check_nakivoTransporter.sh $ARG1$
```

(Arguments are passed by Icinga Check command)

Restart NRPE after changes


---
## Usage

### Repository Check

```bash
check_nakivoRepoState.sh <repo_name> [--warn-reclaim <GB>] [--crit-reclaim <GB>] [--warn-free <GB>]    [--crit-free <GB>] [--warn-alloc <GB>]   [--crit-alloc <GB>]
```
Example:

```bash
check_nakivoRepoState.sh repository-01 --warn-free 8000 --crit-free 5000 --warn-reclaim 10000 --crit-reclaim 15000
```
---

### Jobs Check

```bash
check_nakivoJobs.sh
```
---

### Transporter Check

```bash
check_nakivoTransporterState.sh <transporter_id> [--warn-load <value>] [--crit-load <value>]
```

Example:

```bash
check_nakivoTransporterState.sh transporter-01 --warn-load 2 --crit-load 4
```
---

## Threshold Semantics

| Metric        | Behavior           |
|--------------|-------------------|
| free          | lower is worse    |
| reclaimable   | higher is worse   |
| allocated     | higher is worse   |
| load          | higher is worse   |

Example:

```
--warn-free 8000 --crit-free 5000
```
- ≤ 8000 → WARNING  
- ≤ 5000 → CRITICAL  

---

## Example Outputs

### Repository Check

```bash
repository-01 [OK]: 12 backups, 9500.00 GB free, 12000.00 GB allocated, 2000.00 GB reclaimable | repository_01_backups=12;;;; repository_01_free_gb=9500.00;8000;5000;; repository_01_allocated_gb=12000.00;;; repository_01_reclaimable_gb=2000.00;10000;15000;;
```
---

### Jobs Check

```bash
[OK]: ID 1 | Daily Backup | OK; ID 2 | Weekly Backup | OK
```
```bash
[WARNING]: ID 1 | Daily Backup | OK; ID 2 | Monthly Backup | PENDING
```
```bash
[CRITICAL]: ID 1 | Daily Backup | OK; ID 2 | Offsite Copy | CRITICAL
```
---

### Transporter Check
```bash
[OK]: Transporter transporter-01 (192.168.1.10), load: 1/4, state: OK, status: Running | transporter_transporter_01_load=1;2;4;0;4
```
```bash
[WARNING]: Transporter transporter-01 (192.168.1.10), load: 3/4, state: OK, status: Running | transporter_transporter_01_load=3;2;4;0;4
```
```bash
[CRITICAL]: Transporter transporter-01 (192.168.1.10), load: 4/4, state: OK, status: Running | transporter_transporter_01_load=4;2;4;0;4
```

---

## Return Codes

| Code | State     |
|------|----------|
| 0    | OK       |
| 1    | WARNING  |
| 2    | CRITICAL |
| 3    | UNKNOWN  |

---

## Notes and Limitations

- The plugins rely on Nakivo CLI output parsing. Changes in CLI output format may break parsing.
- No official API is used (Reason: Licensing)
- Each check follows a single responsibility principle.
- Credentials are passed via CLI and should be protected via file permissions.

---

## License

MIT
