# Optional simulated temporary Grandmaster

This entire directory is outside the normal portable CUDU path. The core
configuration defaults to `PTP_ROLE=external-gm`; no core command references
or starts these scripts.

The profile falsely advertises class-6 quality. It is only for an explicitly
authorized isolated-lab diagnostic with every O-RU radio and PA disabled. It
must never be used as a fallback for a missing external GM, connected to a
shared timing network, or counted as successful production CUDU timing.

Only after separate operator authorization:

```bash
cd optional/temp-gm
cp temp-gm.env.example temp-gm.env
./render-temp-gm.sh
sudo ./start-temp-ptp-gm.sh
sudo ./check-temp-ptp-gm.sh
sudo ./stop-temp-ptp-gm.sh
```

The holdover, isolated-servo, wire-check and tuning helpers are retained here
for the same optional diagnostic. Read each script before use.
