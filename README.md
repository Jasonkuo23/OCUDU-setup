# Portable OCUDU CUDU deployment

This directory is a self-contained deployment package for OCUDU CU-CP,
CU-UP and the 90-MHz/4T4R Open Fronthaul DU. Copy the entire directory to an
apt-based Ubuntu/Debian x86-64 machine; no path inside the package is tied to
the original host.

The destination still needs a suitable dedicated fronthaul NIC with hardware
timestamping/PHC support, enough CPU cores and hugepages, an external telecom
Grandmaster, and an O-RU configured for the same radio profile.

## Site configuration

`config/site.env` is the only site-specific source of truth. Create it from the
included example and edit it for the destination machine:

```bash
cd /path/to/ocudu-cudu-portable
./cudu.sh init
editor config/site.env
```

Verify these groups before setup:

- 5GC: `AMF_IP`, `AMF_PORT`, `UPF_IP`, PLMN, TAC and SST.
- N2/N3: interfaces, VLAN parent/ID and local CIDRs/IPs.
- O-RU/OFH: management IPs, NIC, MACs, VLANs, eAxC ports and MTU.
- External PTP: `GM_IP`, `PTP_DOMAIN` and the active `PTP_UDS` socket.
- Host: hugepages, DU cpuset, worker CPUs and IRQ CPUs.
- Radio: ARFCN, band, bandwidth, SCS, PCI, antennas and compression.

`RU_MGMT_ADDR` intentionally has no default. Set it to an operator-confirmed,
unused host CIDR on the fronthaul subnet; it must differ from `RU_IP` and
`GM_IP`. Generated YAML is written to `config/generated/` and must not be
edited directly.

## Automatic setup and CU startup

```bash
cd /path/to/ocudu-cudu-portable
./cudu.sh init
editor config/site.env
sudo ./setup.sh
./cudu.sh render
sudo ./cudu.sh check
sudo ./cudu.sh build
sudo ./cudu.sh up
sudo ./cudu.sh status
sudo ./cudu.sh logs
```

`setup.sh` installs required packages, configures the selected N2/N3 and
fronthaul addresses, allocates hugepages and renders configuration. It does
not start OCUDU or enable the DU. Plain `up` starts only CU-CP and CU-UP.

Optional setup variants:

```bash
sudo ./setup.sh --skip-packages
sudo ./setup.sh --skip-network
```

The runtime network and hugepage changes may need equivalent persistent
Netplan/systemd/boot configuration on a production host.

## Manual CU startup and verification

Run this after `setup.sh` has completed and the image has been built. Rendering
again is safe and ensures the containers use the latest `config/site.env`:

```bash
cd /path/to/ocudu-cudu-portable
./cudu.sh render
sudo docker compose --env-file config/site.env up -d cu-cp cu-up
sudo docker compose --env-file config/site.env ps cu-cp cu-up
```

Collect the CU runtime, SCTP and application-log evidence:

```bash
sudo docker inspect \
  -f '{{.Name}} status={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}}' \
  ocudu-cu-cp ocudu-cu-up
sudo ss -H -n -A sctp state established
sudo docker logs ocudu-cu-cp --tail 250
sudo docker logs ocudu-cu-up --tail 250
```

CU startup is successful only when all of the following are true:

- `ocudu-cu-cp` and `ocudu-cu-up` report `running=true` and `restarts=0`.
- CU-UP receives a successful E1 Setup Response from CU-CP.
- N2 SCTP from `N2_LOCAL_IP` to `AMF_IP:AMF_PORT` is `ESTAB`.
- CU-CP receives `NGSetupResponse` and reports the configured PLMN as supported.
- Neither CU log contains a fatal configuration, bind, SCTP or repeated restart
  error.

Container state alone is not sufficient: E1, N2 and NG Setup evidence must all
be present. To stop only the CU services:

```bash
sudo docker compose --env-file config/site.env stop cu-up cu-cp
```

## Manual DU startup and verification

Start CU-CP and CU-UP first and confirm the preceding CU checks. Do not start
the DU with a raw `docker compose up` command because that bypasses the package
safety workflow. After independently confirming external PTP lock, the O-RU
profile, radio/PA disabled state and RF environment, run:

```bash
cd /path/to/ocudu-cudu-portable
sudo ./setup-ofh-performance.sh
sudo ./check-cudu-ofh-gates.sh
sudo env RF_ENVIRONMENT_CONFIRMED=1 \
  RU_RADIO_DISABLED_CONFIRMED=1 \
  RU_PTP_LOCK_CONFIRMED=1 \
  ./cudu.sh pre-rf
```

Collect evidence without stopping CU-CP just to flush logs:

```bash
sudo docker compose --env-file config/site.env --profile ofh ps
sudo docker inspect \
  -f '{{.Name}} status={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}}' \
  ocudu-cu-cp ocudu-cu-up ocudu-du-ofh
sudo ss -H -n -A sctp state established
sudo docker logs ocudu-cu-cp --tail 250
sudo docker logs ocudu-cu-up --tail 250
sudo docker logs ocudu-du-ofh --tail 250
sudo tail -n 250 logs/du-ofh.log 2>/dev/null || true
```

DU startup is successful only when all of the following are true:

- CU-CP, CU-UP and DU all report `running=true` and `restarts=0`.
- F1-C SCTP on port `38472` is `ESTAB` in the host network namespace.
- CU-CP and DU evidence shows `F1 Setup: Procedure completed successfully`.
- E1 and N2 SCTP remain established and NG Setup remains healthy after the DU
  starts.
- The O-RU still reports PTP lock and every radio/PA remains disabled/off.

If F1 Setup fails, preserve the logs and inspect carrier, PTP, VLAN, MAC and
eAxC settings. Do not bypass a failed gate or enable the radio. Stop the DU and
restore the host-global tuning with:

```bash
sudo docker compose --env-file config/site.env --profile ofh stop du
sudo ./restore-ofh-performance.sh
```

## DU, external PTP and RF safety

The supported core flow uses `PTP_ROLE=external-gm`. Before starting the DU,
verify all of the following independently:

- the fronthaul link has stable 10-Gbps carrier and hardware timestamping;
- host `ptp4l` reports SLAVE on the configured domain and socket;
- the O-RU reports PTP lock and exactly matches the configured 90-MHz/4T4R
  VLAN, MAC and eAxC profile;
- every O-RU radio and PA remains disabled/off;
- the RF environment and authorization have been confirmed.

Then run the guarded pre-RF flow:

```bash
sudo ./setup-ofh-performance.sh
sudo ./check-cudu-ofh-gates.sh
sudo env RF_ENVIRONMENT_CONFIRMED=1 \
  RU_RADIO_DISABLED_CONFIRMED=1 \
  RU_PTP_LOCK_CONFIRMED=1 \
  ./cudu.sh pre-rf
sudo ./cudu.sh status
```

Success requires CU-CP, CU-UP and DU to remain running, E1 and F1 SCTP to be
established, and an explicit successful F1 Setup message. The generated DU
base configuration always keeps `cell_cfg.enabled: false`; `pre-rf` supplies a
guarded runtime override while the physical O-RU radio/PAs remain off.

To stop the DU and restore host-global performance settings:

```bash
sudo docker compose --env-file config/site.env --profile ofh stop du
sudo ./restore-ofh-performance.sh
```

## Optional temporary Grandmaster

The core setup, prompt and commands do not use a temporary Grandmaster. All
files for that explicitly opt-in, isolated diagnostic are contained under
`optional/temp-gm/`. See its own README only when that diagnostic has been
separately authorized; never use it as an automatic fallback for missing
external timing or as authorization for RF transmission.

## Included layout

```text
ocudu-cudu-portable/
├── config/
│   ├── site.env.example
│   └── templates/          # CU-CP, CU-UP and 90-MHz/4T4R DU only
├── logs/
├── optional/
│   └── temp-gm/            # isolated and unused by the default flow
├── Dockerfile
├── compose.yaml
├── FRESH-START-PROMPT.md
├── cudu.sh
├── setup.sh
├── render-config.sh
└── OFH validation/performance helpers
```

The package intentionally excludes the older 20-MHz diagnostic profile, UE
attach, smoke-test, packet-capture and recovery-snapshot helpers.

## Troubleshooting order

1. Run `sudo ./cudu.sh check`.
2. Confirm N2 reachability to the AMF and N3 routing toward the UPF.
3. Confirm fronthaul carrier, 10-Gbps speed and PHC support.
4. Confirm external PTP SLAVE state and O-RU lock/radio state.
5. Run `sudo ./check-cudu-ofh-gates.sh`.
6. Inspect `sudo ./cudu.sh logs` and `logs/du-ofh.log`.

Do not bypass a timing, carrier, configuration or RF-safety gate to make the
DU start.
