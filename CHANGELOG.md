# Changelog

## [0.2.0](https://github.com/eschizoid/stride/compare/v0.1.0...v0.2.0) (2026-08-04)


### ⚠ BREAKING CHANGES

* every machine JSON response is now wrapped. Success is {schema_version:1, data:<payload>}; errors are {schema_version:1, error:{code, message}} — discriminate on which key is present. Deterministic (no timestamps), so golden comparisons stay stable. Tool callers read fields under .data and branch on .error.code. Human table output is unchanged. Made default (not gated) since the user base is still small. stride skill + e2e updated to the enveloped shape.
* rename prescriptions to plan across the CLI and data model

### Features

* add the pace-based load engine (rTSS/sTSS) as pure, tested math ([2af63fa](https://github.com/eschizoid/stride/commit/2af63fad7ae45bc6e08ccd69427877018c92cee9))
* aligned time+dist+alt stream triple for the pace engine ([938675d](https://github.com/eschizoid/stride/commit/938675d345a8e7aa40f724d8848b9e0e6662e3b5))
* aligned time+dist+alt stream triple for the pace engine (slice 2 foundation) ([b54c777](https://github.com/eschizoid/stride/commit/b54c777110a32e7feb9143de963f9912dbe2562f))
* auto-derive per-sport FTP so power-intensity applies to ANY sport ([5780fcc](https://github.com/eschizoid/stride/commit/5780fcc2df1de49f2a912068db6c3a0bd014a7b3))
* compare command — this period vs the one before it ([82ad357](https://github.com/eschizoid/stride/commit/82ad357932446b392d9c63de3dfa6f434bacd55e))
* complete a rest-day prescription without an activity id ([e195a92](https://github.com/eschizoid/stride/commit/e195a9267273bcdfeddacbf47b029a198699a0d2))
* count pace (rtss) load as measured/high-confidence in reports ([e6ec8f8](https://github.com/eschizoid/stride/commit/e6ec8f8cf85fee27bdd7e7bf740e911e3b3b68d0))
* Critical Power (CP/W') least-squares fit ([0578323](https://github.com/eschizoid/stride/commit/0578323269bf5c964df417e1b04cea2d4a2b4e93))
* expand doctor with confidence distribution + config completeness (P8) ([d9154a9](https://github.com/eschizoid/stride/commit/d9154a94e7efd5a570529f834a2aebaab5b768fc))
* fix pace-engine stop deflation and close review gaps ([fa10961](https://github.com/eschizoid/stride/commit/fa10961ab7040640d4e3971a7cab7ea6dc805e24))
* FTP is fully derived per sport — remove the config concept ([4bdfe88](https://github.com/eschizoid/stride/commit/4bdfe88f6085be42c437b6be0823850a9937d9ef))
* grade-adjusted pace algorithm (Minetti 2002) for runs ([67cb797](https://github.com/eschizoid/stride/commit/67cb797fe2da1c3561aa567b6516ae278185e88e))
* grade-adjusted pace algorithm (Minetti 2002) for runs ([0add058](https://github.com/eschizoid/stride/commit/0add0587a2d08b92a2d8ff9af6b7176023140e59))
* import Strava account exports, no API credentials needed ([95fc3e9](https://github.com/eschizoid/stride/commit/95fc3e9c6ee2bc4a2bbd66a34ff480b6d0ec4f5a))
* intensity from power for power rides (fixes hard-effort mislabel) ([6ca5bf4](https://github.com/eschizoid/stride/commit/6ca5bf4fab2e7fc27bf75b330674458333969577))
* mean-max power curve helper (best power at the duration ladder) ([7bd7fa4](https://github.com/eschizoid/stride/commit/7bd7fa459ccb62e540cb614277a911fba865020c))
* **new-compiler:** app.roc compiles clean on the new compiler — 0 errors ([179a56d](https://github.com/eschizoid/stride/commit/179a56d94526b05ea709c2d934feaf5cb016b082))
* pace engine — NGP + derived threshold pace (ADR-0003 slice 2) ([c30b720](https://github.com/eschizoid/stride/commit/c30b72094a8f3012deec1d30a2f6ca45682b19af))
* pace rung in tss_ladder (power -&gt; pace -&gt; HR -&gt; RPE -&gt; RE) ([661259c](https://github.com/eschizoid/stride/commit/661259ce96e476b0719148872146c5f7a0e41c2f))
* pace scoring for swim + indoor — flat-speed path (ADR-0003 slice 3) ([bad2e78](https://github.com/eschizoid/stride/commit/bad2e781fcff45d7aea2fedf100ac2531abd4225))
* pace scoring for swim + indoor — flat-speed path (ADR-0003 slice 3) ([0035fe9](https://github.com/eschizoid/stride/commit/0035fe9ef2d5780a9dd6df895f05b48250bbf32d))
* pace-intensity split (pi_* from pace for runs/swims) ([c9ea8b1](https://github.com/eschizoid/stride/commit/c9ea8b125d113709edc61823ab31bcd866e4fe28))
* pace-intensity split for pace sports (pi_* from pace) ([830cd0e](https://github.com/eschizoid/stride/commit/830cd0e736a39560ed5d7c6ea85b664bcca0e873))
* per-sport HR zones (hr_z*_max_&lt;sport&gt;) with global fallback ([582a1d7](https://github.com/eschizoid/stride/commit/582a1d7c0b9c58fe3ce1c2d2cf50704a50502028))
* per-sport HR zones (hr_z*_max_&lt;sport&gt;) with global fallback ([b639902](https://github.com/eschizoid/stride/commit/b639902cd6eda2ed535e31d17b36c7163bc34b35))
* per-sport pace-engine config keys (threshold_pace_&lt;sport&gt;, model_&lt;sport&gt;) ([ab7cf7e](https://github.com/eschizoid/stride/commit/ab7cf7e29d0085a97505fa50b890b18733824390))
* persist load confidence + stop labelling mixed load as TSS (P5) ([365336d](https://github.com/eschizoid/stride/commit/365336d5d6907e755c8fa8b3739d4ba9e8d3b9b8))
* power-based intensity across all surfaces, generic per-sport FTP ([92705cb](https://github.com/eschizoid/stride/commit/92705cb81cef1bea2dbe44563568f6685bfd8e23))
* power-curve command — power-duration curve + Critical Power ([f0ab7e3](https://github.com/eschizoid/stride/commit/f0ab7e3b752cd372083ccf271113d72000f9ba6f))
* power-duration curve + Critical Power (ADR-0004) ([dd312f3](https://github.com/eschizoid/stride/commit/dd312f333b4f46a9566baca0dca91a6d8d41ecf6))
* rename prescriptions to plan across the CLI and data model ([9d8ca62](https://github.com/eschizoid/stride/commit/9d8ca62f270f1abf2ea7df7c0f5d7f99534a7ecc))
* request altitude streams so grade-adjusted pace has its input ([d112eeb](https://github.com/eschizoid/stride/commit/d112eeb803c99953f94044fafa4568eb2c9de232))
* request distance stream explicitly alongside altitude ([fa18498](https://github.com/eschizoid/stride/commit/fa184983774519e1d27f3c56b590b95a4562e8d8))
* session-RPE ratings, sport-aware load ladder, doctor command, load provenance ([897652a](https://github.com/eschizoid/stride/commit/897652a823e08216d9bfca30479a7d25f06df63d))
* sport-aware progress — EF, speed/HR, and RPE lenses ([e86a58b](https://github.com/eschizoid/stride/commit/e86a58b664e1d823d3a3518748c60d4baac0f89f))
* store per-activity power-duration curve (best_&lt;dur&gt;_w columns) ([fadf38c](https://github.com/eschizoid/stride/commit/fadf38c37c9801fcf589fa59038f4bc3a40efc17))
* stride plan shows the current week by default; plan all for full log ([fb3de5e](https://github.com/eschizoid/stride/commit/fb3de5ec68fb41539f7883b348744bceec0d848a))
* STRIDE_API_BASE override + mock Strava server for network-free sync testing ([ac359f4](https://github.com/eschizoid/stride/commit/ac359f4d7bb9e141c760ce267f44e183ae4fa6c9))
* surface measured vs estimated load share on the fitness number (grill [#2](https://github.com/eschizoid/stride/issues/2)) ([8596805](https://github.com/eschizoid/stride/commit/859680507d6af76e8cf10adcf88023dcc707c845))
* timezone-aware "today" via IANA zone (DST-correct) ([8be7a6a](https://github.com/eschizoid/stride/commit/8be7a6a1ce5350490e0bd5c9e0b466cf9e7c4941))
* uniform per-sport FTP (ftp_&lt;sport&gt;), no special-cased cycling key ([3c79541](https://github.com/eschizoid/stride/commit/3c79541f73c50d15c489abd3a5406d379407bf10))
* version all JSON output in a { schema_version, data } envelope ([8b5fea8](https://github.com/eschizoid/stride/commit/8b5fea8e60232f9f1055d3fb4367274a9f0fc272))
* wire NGP + derived threshold pace into scoring (slice 2) ([0a6fd41](https://github.com/eschizoid/stride/commit/0a6fd41dffd656563ab2a7dbace14b5dc7c2005a))


### Bug Fixes

* add stable ORDER BY tiebreakers for deterministic output ([202e305](https://github.com/eschizoid/stride/commit/202e30532dd54dda23478b66e9f9d716f20d613a))
* Bool-type the redacted/rest JSON fields (bare True serialized as "True") ([7c356b8](https://github.com/eschizoid/stride/commit/7c356b83a5282772699af278f531012ab12c0494))
* compare zero-prior verdict; feat: pace column for distance sports (runs/rows) ([aaa4326](https://github.com/eschizoid/stride/commit/aaa4326e7c1e94f97eb1184834db51a23281a9b7))
* decode UnixBytes argv from basic-cli 0.21 (commands were all showing help) ([a7f1377](https://github.com/eschizoid/stride/commit/a7f13776f03286080b2bc0c01aaeeba07010321e))
* dist_alt_time drops null sentinels in the time stream too ([9370a78](https://github.com/eschizoid/stride/commit/9370a7896b8c4141eb3a7785e28d07bd0ef26ebe))
* filter non-physiological power samples before NP/FTP (grill [#4](https://github.com/eschizoid/stride/issues/4)) ([fd4c0f2](https://github.com/eschizoid/stride/commit/fd4c0f2197b059c897e45919e3f72067916e23be))
* flat-path fallback when altitude is all-null + strengthen dist_time test ([7b59521](https://github.com/eschizoid/stride/commit/7b59521e8b572ca63520bb9d5111a018b356479c))
* freeze per-sport FTP + converge analyze to a fixed point (derived-FTP bug) ([9c67470](https://github.com/eschizoid/stride/commit/9c674703c896c6e75cd4b70b7449a21bed5715b6))
* gate pi_* power/pace choice on power samples, not pi_ftp ([ae4627c](https://github.com/eschizoid/stride/commit/ae4627cb649e1586505ac6e85b847a28740ffa93))
* guard non-positive CP/W' fit + reuse shared power-curve ladder ([39d9214](https://github.com/eschizoid/stride/commit/39d92145cd9fcbf9ff8d26b3a4fb9577465c89a5))
* heap-corruption crashes, FTP-less power scoring, and doctor JSON bool ([532a341](https://github.com/eschizoid/stride/commit/532a341c9768a0566403fb29fd9f7e06a4ec00c1))
* hide skipped tombstones from the default plan view ([38d97f3](https://github.com/eschizoid/stride/commit/38d97f34a8e09c6b8dcf73e99f2c7dd6b5fd0973))
* honest zone-gap wording (no Z5 HR time, not 'no VO2max stimulus') ([3a6cd62](https://github.com/eschizoid/stride/commit/3a6cd621df8c3103c24c4b3d47bf24049818a3ca))
* make token save and daily_load rebuild atomic ([35c0a5c](https://github.com/eschizoid/stride/commit/35c0a5c556f7f19f502b131c6844ff97613ab37b))
* **new-compiler:** close complete_rest! fn block (concurrent-edit dropped a brace) ([fbe9579](https://github.com/eschizoid/stride/commit/fbe95794f8206191616f41f235654aa2bd13c835))
* **new-compiler:** Command is now := (nominal, constructable) so app.roc can match it ([30c41b1](https://github.com/eschizoid/stride/commit/30c41b1e5c3b3bc424739af8c5aded78f293d5b9))
* perms check used BSD stat -f, which is --file-system on Linux CI ([75fea86](https://github.com/eschizoid/stride/commit/75fea866cb1d610426a11836f458c263d7dbe1c9))
* prune activities deleted on Strava during sync ([592e557](https://github.com/eschizoid/stride/commit/592e55703230c94ddf741125a9e84c64ae4fa958))
* re-planning revises the open session in place (no skipped tombstones) ([faa5b2b](https://github.com/eschizoid/stride/commit/faa5b2b23eb9a5f33d9b787307e3086533da8faa))
* resolve empty-sport activities to the global HR zones only ([76e07ee](https://github.com/eschizoid/stride/commit/76e07eed3ac6d3d0ef2234622a5c3d55488093dc))
* return clean no-data state instead of crashing empty-db reads ([22b43c9](https://github.com/eschizoid/stride/commit/22b43c9e25f4bf804d3726fa53e465d1f570684e))
* **security:** pass untrusted values as args/escape them instead of shell/SQL interpolation ([d7bc916](https://github.com/eschizoid/stride/commit/d7bc916340413ace30e8593e487fad646aae46ee))
* **security:** secure_perms! passes dir as sh -c positional arg, not interpolated ([6063d4f](https://github.com/eschizoid/stride/commit/6063d4fc483f20f94f48bad9ca54d255fb25b13c))
* stop leaking Strava credentials (config get + file permissions) ([8251626](https://github.com/eschizoid/stride/commit/8251626118ffc8e92968c1573d036fdb211a7622))
* validate STRIDE_API_BASE and fail-closed on secret config keys ([5f4423d](https://github.com/eschizoid/stride/commit/5f4423d89c4c55d404daf38e74155f85caf45dd5))
* **windows:** fall back to USERPROFILE when HOME is unset (home_dir! helper) ([ddf8e3c](https://github.com/eschizoid/stride/commit/ddf8e3cd5f8c70ef28852d152217c760e6b8bd90))
* wrap long table cells across rows (keep table ≤80 cols) ([4b2fb19](https://github.com/eschizoid/stride/commit/4b2fb19a213c2a6e19bafddf21ce927d978910a3))
* wrap long table cells across rows instead of overflowing the terminal ([58b1710](https://github.com/eschizoid/stride/commit/58b171016be28aded949452240a329b761151599))


### Performance Improvements

* early-exit cfg_f64 instead of scanning the whole config list ([1913996](https://github.com/eschizoid/stride/commit/1913996b1294dd7c5880d47abc897ff406c8f728))

## 0.1.0 (2026-07-30)


### ⚠ BREAKING CHANGES

* consistent JSON contract across commands
* progress is date-anchored; auto-named rides compare similar distances only

### Features

* add output (kJ) metric to top for total work ranking ([b432178](https://github.com/eschizoid/stride/commit/b4321789dba6b7991e69c572fb650c2d0681d02b))
* add progress command to track improvement on a repeated workout ([55974c4](https://github.com/eschizoid/stride/commit/55974c44cdb520687fa802db34bb0d378693a8a6))
* add pz command showing power-zone watt ranges from FTP ([b42123f](https://github.com/eschizoid/stride/commit/b42123fc005b70de990de6442938cb5d80777526))
* add top command to rank activities by a metric ([25b0f9e](https://github.com/eschizoid/stride/commit/25b0f9e9478c723771f77f32846eab32cacc5b1a))
* asked-date marker uses a solid triangle ([df787e1](https://github.com/eschizoid/stride/commit/df787e150bd61b7400d6fca9d2d6159e4d9d63c7))
* auth opens the authorize URL in the browser automatically ([c266b69](https://github.com/eschizoid/stride/commit/c266b694c70ccaa0a2b43f54a239d1a4451e7fa3))
* bare progress defaults to the latest workout; honest message for EF-less days ([9e4d2e2](https://github.com/eschizoid/stride/commit/9e4d2e2abd351f7594ab81771624a482ffc13c27))
* consistent full-name table headers with acronyms across commands ([a8c929e](https://github.com/eschizoid/stride/commit/a8c929e3596db0b32b15c7fb17f73cc79607bf4c))
* consistent JSON contract across commands ([ecd2e38](https://github.com/eschizoid/stride/commit/ecd2e3851d45670993557215d7922b51c5962dde))
* ef bar column in progress (ASCII, scaled to best; &lt; marks asked date) ([b7964c3](https://github.com/eschizoid/stride/commit/b7964c327c949aee6d84844d8193d6e9b2bed92c))
* progress accepts a date, resolving that day's workout(s) ([cf8020d](https://github.com/eschizoid/stride/commit/cf8020da0e317610f7ff034b889a351bf236750d))
* progress bars scale worst-to-best, gap rows for 90-day breaks, explicit asked marker ([0ce1ba7](https://github.com/eschizoid/stride/commit/0ce1ba77f85ebf06f00b9a5a66eea02131a2f641))
* progress is date-anchored; auto-named rides compare similar distances only ([f6ac8b9](https://github.com/eschizoid/stride/commit/f6ac8b9d8d6cc1d5866fe85debc08d189b6afad1))
* progress shows last-vs-best EF gap line ([91ba735](https://github.com/eschizoid/stride/commit/91ba7354a679ac3f9bc40a1beaf492ea70561295))
* push FTP to Strava when set locally, so they stay in sync ([0b10eda](https://github.com/eschizoid/stride/commit/0b10eda305ee7ec0571bbe710525fa5411fe3e53))
* solid block ef bar (constant-height, single-width glyph) ([5a3efe5](https://github.com/eschizoid/stride/commit/5a3efe5714986bf16921346c31e221706363b12e))


### Bug Fixes

* auth also requests profile:read_all so athlete FTP stays readable ([603626e](https://github.com/eschizoid/stride/commit/603626eb8116cfc780aaeb7823710d3053e15e89))
* compute form (TSB) same-day so it reflects current fatigue ([ae97520](https://github.com/eschizoid/stride/commit/ae975203526a3f4e935df1ba2c48989b8fe03636))
* honest degraded messages in best-effort paths ([93ba287](https://github.com/eschizoid/stride/commit/93ba2874a8e3bbadaec252000c4729864feed477))
* metrics recompute when the algorithm changes; single stream-response policy ([4dc45bc](https://github.com/eschizoid/stride/commit/4dc45bcad107edcf640b9d7d1273146695ae6960))
* progress verdict includes the average EF ([668ce91](https://github.com/eschizoid/stride/commit/668ce91597da13c21358b44bc932a0e39fe0d720))
* re-auth reuses stored client credentials instead of requiring env vars ([82451b5](https://github.com/eschizoid/stride/commit/82451b53befdfed1200c7c9f857fa08ec325073d))
* request profile:write scope in auth so FTP sync to Strava works for new tokens ([c79bd47](https://github.com/eschizoid/stride/commit/c79bd47d2896b8f9be238d2bb311fe28d89b92fe))
* show per-activity distances with one decimal ([50986fc](https://github.com/eschizoid/stride/commit/50986fcdcec76a48120e809afd87994e749ad3fb))


### Miscellaneous Chores

* reset release baseline so the first public release is 0.1.0 ([1520a9f](https://github.com/eschizoid/stride/commit/1520a9f8bf97d1895c32620571c7a097fa6da4a4))

## Changelog

All notable changes to stride are documented here. The release workflow publishes
the section matching each version tag as that release's notes, so keep the newest
version at the top in the format below (`## [X.Y.Z] - YYYY-MM-DD`).
