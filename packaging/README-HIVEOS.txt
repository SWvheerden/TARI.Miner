TARI.Miner C29 v1.1.6 - HiveOS
================================

Community Tari Cuckaroo29 CUDA miner. No developer fee.

HiveOS custom miner setup
-------------------------
1. Create an XTM wallet entry containing your Tari wallet address.
2. Create a Flight Sheet and choose "Configure in miner" for the pool.
3. Select Custom miner and use these values:

   Miner name: tari-miner-hiveos
   Installation URL:
   https://github.com/JustAResearcher/TARI.Miner/releases/download/v1.1.6/tari-miner-hiveos-1.1.6.tar.gz
   Hash algorithm: cuckaroo29
   Wallet and worker template: %WAL%.%WORKER_NAME%
   Pool URL: stratum+tcp://taric29-ca.luckypool.io:3111
   Pass: x

4. Apply the Flight Sheet. Open Miner Log to confirm each GPU is assigned an
   sm_86, sm_89, or sm_120 backend and that shares are accepted.

All supported NVIDIA GPUs are enabled by default. Mixed RTX 30, RTX 40, and
RTX 50 rigs are supported because the launcher selects a backend separately
for every GPU.

Optional extra config
---------------------
Use the Flight Sheet's Extra config arguments field for miner options:

  --pipeline 1

To select device indexes, add this token to Extra config arguments:

  TARI_DEVICES=0,2

The integration writes one log per GPU and reports per-GPU graph rates,
temperatures, fans, accepted shares, and rejected shares to the HiveOS agent.
The graph rate is averaged over about the last 60 seconds (earlier versions
showed the average since start), so it drops while the pool is unreachable.
A GPU whose log has had no speed report for 90 seconds shows 0.
It does not change clocks, voltage, fans, or power limits.

Because of this, the HiveOS low-hashrate watchdog sees a pool outage within
about 60-90 seconds. Prefer a miner restart, or a longer delay, over a rig
reboot in its settings, so a short pool outage does not reboot the rig.

Accepted and rejected shares are the pool's own replies to submitted shares.
They are not proof of payout; check the pool's dashboard for that.

Manual reinstall on a rig
-------------------------
/hive/miners/custom/custom-get \
  https://github.com/JustAResearcher/TARI.Miner/releases/download/v1.1.6/tari-miner-hiveos-1.1.6.tar.gz \
  -f

Then reapply the Flight Sheet or run `miner restart`.
