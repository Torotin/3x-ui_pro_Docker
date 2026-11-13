# AWG akar stability canary evidence

Date (UTC): 2026-11-08T14:58:34Z  
Controller API: `http://192.168.10.1:9090`  
Provider: `akar`  
AWG node: `🇵🇱 amneziawg`  
Backup dir: `/opt/docker-proxy/_backup/awg-akar-stability-20261108140222`

## Result

- Status: `DONE_WITH_CONCERNS`
- API heuristic: `PASS`
- Last 6 zero-count: `1`
- Non-zero delays under 200 ms: `true`
- Manual smoke: `MANUAL_SMOKE=PENDING_USER`; operator must confirm client TUN/browser traffic separately.
- Regression VLESS: `🇵🇱 vless-tcp-reality-akar.crabdance.com-autogen` delay `60` ms at `2026-11-08T14:58:32.91142808Z`; healthy=`true`.

## Sanitized profile summary

- Host touched by earlier apply: `vps-intezio-akar`
- Inbound: id `5`, protocol `amneziawg`, port `443`, enabled
- Canary profile summary: `S=[16,16,16,16]`, `H=[1,2,3,4]`, `jc/jmin/jmax=4/50/120`, `disableCookies=false`, client `keepAlive=25`
- Key material: omitted from this evidence

## Before history tail

| time | delay |
| --- | --- |
| 2026-11-08T14:18:07.26318776Z | 62 |
| 2026-11-08T14:18:08.9417972Z | 62 |
| 2026-11-08T14:22:14.15002856Z | 61 |
| 2026-11-08T14:24:05.39978768Z | 62 |
| 2026-11-08T14:24:05.95319312Z | 62 |
| 2026-11-08T14:27:01.64158376Z | 61 |
| 2026-11-08T14:27:11.27734336Z | 62 |
| 2026-11-08T14:27:16.53380768Z | 62 |
| 2026-11-08T14:27:26.19817352Z | 75 |
| 2026-11-08T14:27:37.3425832Z | 69 |

## Observation samples

| sample | observed_at | history_time | delay | alive |
| --- | --- | --- | --- | --- |
| 1 | 2026-11-08T14:27:50Z | 2026-11-08T14:27:43.39758648Z | 73 | true |
| 2 | 2026-11-08T14:32:57Z | 2026-11-08T14:32:50.49677216Z | 61 | true |
| 3 | 2026-11-08T14:38:04Z | 2026-11-08T14:37:57.88520344Z | 75 | true |
| 4 | 2026-11-08T14:43:11Z | 2026-11-08T14:43:04.6992556Z | 63 | true |
| 5 | 2026-11-08T14:48:18Z | 2026-11-08T14:48:11.79876776Z | 62 | true |
| 6 | 2026-11-08T14:53:25Z | 2026-11-08T14:53:18.62321736Z | 62 | true |
| 7 | 2026-11-08T14:58:32Z | 2026-11-08T14:58:30.41182864Z | 0 | false |

## AWG_AUTO delay triggers

| sample | observed_at | ok | target_delay |
| --- | --- | --- | --- |
| 1 | 2026-11-08T14:27:48Z | true | 73 |
| 2 | 2026-11-08T14:32:55Z | true | 61 |
| 3 | 2026-11-08T14:38:02Z | true | 72 |
| 4 | 2026-11-08T14:43:09Z | true | 63 |
| 5 | 2026-11-08T14:48:16Z | true | 62 |
| 6 | 2026-11-08T14:53:23Z | true | 62 |
| 7 | 2026-11-08T14:58:30Z | true |  |

## Regression glance

| node | history_time | delay | healthy |
| --- | --- | --- | --- |
| 🇵🇱 vless-tcp-reality-akar.crabdance.com-autogen | 2026-11-08T14:58:32.91142808Z | 60 | true |

## Notes

- Observation window used 7 samples from local UTC time `2026-11-08T14:27:50Z` through `2026-11-08T14:58:32Z`.
- The local agent cannot drive the user's TUN/client browser path, so manual smoke remains pending by design.
