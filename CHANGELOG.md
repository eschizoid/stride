# Changelog

## [0.7.0](https://github.com/eschizoid/stride/compare/v0.6.0...v0.7.0) (2026-08-18)


### ⚠ BREAKING CHANGES

* machine output is requested, never inferred. Stride no longer reads any agent or harness environment variable to choose its format. If a caller that used to receive JSON now gets human tables, pass --json on the command (any argv position) or export STRIDE_FORMAT=json for the session — STRIDE_FORMAT is unchanged and is now the only environment input. The coach skill shipped in this repo already passes --json on every query; a copy of that skill installed outside the repo must be refreshed.

### Features

* callers ask for JSON — drop environment detection, answer machines in envelopes, and schema every published payload ([535acfd](https://github.com/eschizoid/stride/commit/535acfd0fcf09a0006c62575a9f25158aeae9148))
* coaching-language boundary guard with closed-set verdict pins ([#167](https://github.com/eschizoid/stride/issues/167)) ([29f1d02](https://github.com/eschizoid/stride/commit/29f1d02414914f9f023325d955c2658072d4b317))
* error envelopes exit non-zero, and an unknown command stops pretending to succeed ([#178](https://github.com/eschizoid/stride/issues/178)) ([3b64cda](https://github.com/eschizoid/stride/commit/3b64cda60fade8902b2e8da0856f7c6ba4bc87c5))
* explicit --json / --human flags for tool-neutral output selection ([#177](https://github.com/eschizoid/stride/issues/177)) ([e323890](https://github.com/eschizoid/stride/commit/e323890126ba3e4835e39afc27668cdf64fec21c))
* FTP derives from the sport family via stored sport_family ([#169](https://github.com/eschizoid/stride/issues/169)) ([39f6a40](https://github.com/eschizoid/stride/commit/39f6a405f2920f683c454598afd00cdccf41302a))
* missing values are flagged, not nulled ([#168](https://github.com/eschizoid/stride/issues/168)) ([fde7724](https://github.com/eschizoid/stride/commit/fde772439ce4cb7136ac262957798cdcfb848fcd))
* personal-baseline primitives — current vs own history with deterministic comparability ([#175](https://github.com/eschizoid/stride/issues/175)) ([785ec04](https://github.com/eschizoid/stride/commit/785ec04972265f9fe442b16e803744b4f40f62a5))
* plan payload gains 28d history and adherence counts ([#173](https://github.com/eschizoid/stride/issues/173)) ([827cccd](https://github.com/eschizoid/stride/commit/827cccd0563705f387d0b0d75a5dbd0c01a5fc48))
* platform failures reach the caller as the contract ([#184](https://github.com/eschizoid/stride/issues/184)) ([6e7afc0](https://github.com/eschizoid/stride/commit/6e7afc08d7713e67ec70767e28cde324b579338e))
* publish the JSON contract as checked-in, validated schemas ([#179](https://github.com/eschizoid/stride/issues/179)) ([68d1ff4](https://github.com/eschizoid/stride/commit/68d1ff4ff1ceedfe3f1753a1cc0602be34c376c3))
* rep-level comparison — the same workout shape across sessions ([#185](https://github.com/eschizoid/stride/issues/185)) ([2515286](https://github.com/eschizoid/stride/commit/2515286c403669c76033b14c1f2f747dcc83be41))
* spend the CP model — W′ balance and time to exhaustion ([#190](https://github.com/eschizoid/stride/issues/190)) ([6af2e21](https://github.com/eschizoid/stride/commit/6af2e21624036bf63dc8841fe2908a9afd0210a6))
* sport words — family filters, honest empty results ([#150](https://github.com/eschizoid/stride/issues/150)) ([25b676c](https://github.com/eschizoid/stride/commit/25b676cd65a06db2b2309441612f531197c4fcaa))
* stimulus history, windowed loads, and threshold trajectory as measurements ([#174](https://github.com/eschizoid/stride/issues/174)) ([17a2f67](https://github.com/eschizoid/stride/commit/17a2f6729bf1f4278462b6115a91644ef89e35ee))
* stride season — training blocks, monthly load, polarization, FTP trajectory ([#192](https://github.com/eschizoid/stride/issues/192)) ([b25d3e9](https://github.com/eschizoid/stride/commit/b25d3e90b2578ae5217c6dac03460aedbf345d16))
* substitute-activity links on skip and unplanned rows in week ([#145](https://github.com/eschizoid/stride/issues/145)) ([072d99e](https://github.com/eschizoid/stride/commit/072d99ef6faf0beb867b9d8ad64c333e535f01ba))
* TSS-weighted confidence coverage on the load aggregates ([#172](https://github.com/eschizoid/stride/issues/172)) ([67430de](https://github.com/eschizoid/stride/commit/67430de81f16bf0bb527f30f9811437ad28811e8))


### Bug Fixes

* a done session refuses skip — completions are permanent evidence ([#153](https://github.com/eschizoid/stride/issues/153)) ([0379529](https://github.com/eschizoid/stride/commit/03795296bd692a9ef238711854bd0351e7c92a86))
* refuse exponent notation in user-supplied ids and counts ([#203](https://github.com/eschizoid/stride/issues/203)) ([768c07e](https://github.com/eschizoid/stride/commit/768c07eda2377aca676e6049489d1e71c08fdf14))
* repair the coach skill contract and add drift tests ([#166](https://github.com/eschizoid/stride/issues/166)) ([1b2ecf2](https://github.com/eschizoid/stride/commit/1b2ecf214edc58a71346489d051efe72410f4945))
* stop the e2e fixture changing the binary's clock mid-run ([#202](https://github.com/eschizoid/stride/issues/202)) ([2c14649](https://github.com/eschizoid/stride/commit/2c14649690fa8794f8b53f4c018bf38daf18c982))
* structure-gated interval detection — judge the segmentation, not the distribution ([#171](https://github.com/eschizoid/stride/issues/171)) ([aa218ef](https://github.com/eschizoid/stride/commit/aa218ef081f041c23dcd23d0956d3d49a1ab8a4b))
* substitution hardening — prune guard, stable ordering, truthful claim semantics ([#147](https://github.com/eschizoid/stride/issues/147)) ([1efa473](https://github.com/eschizoid/stride/commit/1efa473bc4c733103b2d485ec210ab659e796fa6))

## [0.6.0](https://github.com/eschizoid/stride/compare/v0.5.0...v0.6.0) (2026-08-14)


### Features

* aerobic decoupling (Pw:HR drift) per activity ([#94](https://github.com/eschizoid/stride/issues/94), [#125](https://github.com/eschizoid/stride/issues/125)) ([5860560](https://github.com/eschizoid/stride/commit/58605603072e4f9fc7bd757321b94499cc4f9f9c))
* aerobic decoupling for pace sports and per-session drift in progress ([#142](https://github.com/eschizoid/stride/issues/142)) ([19eacde](https://github.com/eschizoid/stride/commit/19eacde17e4a85bbe02294ef2f30135e214340f8))
* complete a planned session from the CLI alone ([#111](https://github.com/eschizoid/stride/issues/111), [#112](https://github.com/eschizoid/stride/issues/112), [#121](https://github.com/eschizoid/stride/issues/121)) ([7527985](https://github.com/eschizoid/stride/commit/752798590b8caafde87051f5d08f7f1a44031826))
* interval detection v1 — session structure (shape, per-rep HR, drift) on activity ([#95](https://github.com/eschizoid/stride/issues/95), [#132](https://github.com/eschizoid/stride/issues/132)) ([2812466](https://github.com/eschizoid/stride/commit/2812466f7598bc29f19325ed18e3584c931c7e7f))
* plan all renders upcoming / this week / last week sections ([#98](https://github.com/eschizoid/stride/issues/98)) ([9bbc0a1](https://github.com/eschizoid/stride/commit/9bbc0a1ca154d1e50a5c26d87498be5c745ed192))
* progress says a lone session is the first, not that it has a comparable ([#96](https://github.com/eschizoid/stride/issues/96), [#126](https://github.com/eschizoid/stride/issues/126), [#128](https://github.com/eschizoid/stride/issues/128)) ([a4804a1](https://github.com/eschizoid/stride/commit/a4804a1514cb9c366d6e5edc6dce6a09b00a016e))
* show rest days and week dividers in the 14-day table ([#99](https://github.com/eschizoid/stride/issues/99)) ([551f833](https://github.com/eschizoid/stride/commit/551f8330721bfd7e819c8b6296faab6311dbfecc))
* sync reports how many activities were new or changed ([#91](https://github.com/eschizoid/stride/issues/91), [#120](https://github.com/eschizoid/stride/issues/120)) ([80e75f6](https://github.com/eschizoid/stride/commit/80e75f66c65d8ded57d6c7858fd1725431fadb37))
* the form verdict names the training state, counts band days honestly, and carries a weekly trend ([#119](https://github.com/eschizoid/stride/issues/119), [#123](https://github.com/eschizoid/stride/issues/123), [#124](https://github.com/eschizoid/stride/issues/124), [#127](https://github.com/eschizoid/stride/issues/127)) ([25e20d5](https://github.com/eschizoid/stride/commit/25e20d58521ec4c3ee59fe15ef44309539f8c2cc))


### Bug Fixes

* bug C root-caused and fixed — SQLite bindings double-free, upstream fix shipped in basic-cli 0.22.0 ([#105](https://github.com/eschizoid/stride/issues/105), [#130](https://github.com/eschizoid/stride/issues/130), [#131](https://github.com/eschizoid/stride/issues/131)) ([7f53561](https://github.com/eschizoid/stride/commit/7f5356193c0edbc955144a4dcd68049c31046a43))
* decoupling honesty — stored signal provenance, coverage and magnitude gates ([#143](https://github.com/eschizoid/stride/issues/143)) ([d7889bc](https://github.com/eschizoid/stride/commit/d7889bc546b3ac5d7ed3b62062c616bab7a6aa92))

## [0.5.0](https://github.com/eschizoid/stride/compare/v0.4.0...v0.5.0) (2026-08-08)


### Features

* progress accepts asc|desc — list sessions newest-first ([#77](https://github.com/eschizoid/stride/issues/77)) ([64e0ac6](https://github.com/eschizoid/stride/commit/64e0ac635498604a6fb67ae30fee95a31d754c8a))
* widen tables to 100 columns so the detail column is readable ([#90](https://github.com/eschizoid/stride/issues/90)) ([308b0f6](https://github.com/eschizoid/stride/commit/308b0f6a2407a7e3b831e3b3eba71131c8b1afe6))


### Bug Fixes

* a concurrent reader can no longer abort analyze ([#81](https://github.com/eschizoid/stride/issues/81)) ([25be2de](https://github.com/eschizoid/stride/commit/25be2de1b87d45158eb727a988c58df890f5bc35))
* estimated watts no longer outrank honest fallbacks (device_watts) ([#74](https://github.com/eschizoid/stride/issues/74)) ([618edce](https://github.com/eschizoid/stride/commit/618edce95a252cc5d4d7c061a92648e92a843bfa))
* progress bars no longer word-wrap mid-bar ([#76](https://github.com/eschizoid/stride/issues/76)) ([c388a16](https://github.com/eschizoid/stride/commit/c388a16a25a7cdff097377f5a7443da29deed470))
* say when the asked session isn't in its own progress table ([#85](https://github.com/eschizoid/stride/issues/85)) ([df4b80f](https://github.com/eschizoid/stride/commit/df4b80fa3badb4e62e9f067f89da886e7ce4c1f1))
* show when a session was actually completed ([#89](https://github.com/eschizoid/stride/issues/89)) ([72cb02d](https://github.com/eschizoid/stride/commit/72cb02d5a57b021a49c6f1fcb752810dfddf55ce))
* stop sorting already-ordered streams, ~100x faster analyze ([#78](https://github.com/eschizoid/stride/issues/78)) ([d640523](https://github.com/eschizoid/stride/commit/d6405238603436ecaaf8c70bff19f53322ce77b5))
* the pace threshold is period-accurate, like FTP ([#82](https://github.com/eschizoid/stride/issues/82)) ([a03bb0a](https://github.com/eschizoid/stride/commit/a03bb0a2086b0ad1f2f1562b313450ff9bc6a29d))

## [0.4.0](https://github.com/eschizoid/stride/compare/v0.3.0...v0.4.0) (2026-08-07)


### Features

* refuse to set a derived key instead of storing it and ignoring it ([#64](https://github.com/eschizoid/stride/issues/64)) ([cea2d89](https://github.com/eschizoid/stride/commit/cea2d89deba96ca9d9863edad6c9343981422aac))
* salvage the pure-Roc improvements from the reverted [#69](https://github.com/eschizoid/stride/issues/69) ([4df8fe9](https://github.com/eschizoid/stride/commit/4df8fe9b0724244f2d1ac2edd4af2e2ae2355f3d))
* score each activity at the FTP in force when it happened ([a668cb5](https://github.com/eschizoid/stride/commit/a668cb52e6e55a61f6b47e4588cf8c6b884035a2))
* stream activities.csv out of the export zip instead of extracting it ([6320854](https://github.com/eschizoid/stride/commit/6320854fdcdd7ea2e0041610845f37d5d890970a))


### Bug Fixes

* build the e2e harness with --opt=dev too ([cbf0ef9](https://github.com/eschizoid/stride/commit/cbf0ef9aa875bc951304885f48a66bb203aa63c6))
* correct the cold-start date comparison and index the period-FTP lookup ([0efe594](https://github.com/eschizoid/stride/commit/0efe594ecabee5e45e954c43376084512757d19f))
* count unanalyzed activities in summary totals, and say when analyze stopped early ([bee27ef](https://github.com/eschizoid/stride/commit/bee27efd5b39d0fef1fd7df7d6712af4bebc32a9))
* emit no speed sample across an unrecorded gap ([f01c199](https://github.com/eschizoid/stride/commit/f01c19946291fb872df67c6ba693260bbe80b011))
* four scoring-accuracy corrections from the training-science audit ([7b81c6d](https://github.com/eschizoid/stride/commit/7b81c6dbddbbf3f03a15dc0447cf2092d3bd0714))
* handle both no-baseline cases in the compare screen, and use False for False ([c177e6e](https://github.com/eschizoid/stride/commit/c177e6e34ee9a6e8140bd94485a53c497bca9d52))
* interpolate cumulative streams so coarse recordings don't spike NGP ([df91559](https://github.com/eschizoid/stride/commit/df915598da14353fa75a2663654d465412a13e58))
* point the justfile at the new compiler so `just test` works locally ([7402ca3](https://github.com/eschizoid/stride/commit/7402ca374cdf397a1fdcd32913c00d312779eaca))
* reject pause-spanning windows when deriving bests ([fc08e4b](https://github.com/eschizoid/stride/commit/fc08e4b0819fd4b69cffae67da0f800c459501ba))
* say when CTL is still warming up, and pin the load model over many days ([f39bf58](https://github.com/eschizoid/stride/commit/f39bf58acf51487f2da58e96d0f0f8f2de23ea7e))
* show the warming-up warning to humans, not only to JSON callers ([0ad2304](https://github.com/eschizoid/stride/commit/0ad23047d9542d1a018a49c6d3f4a5a5fc7b3f6d))
* sort stream samples before resampling, and stop dropping light sessions ([cda9c8f](https://github.com/eschizoid/stride/commit/cda9c8f48305a10623313bb30bc457dccf7aefd9))
* stop `plan` showing duplicate rows for a re-planned day you then missed ([a87b752](https://github.com/eschizoid/stride/commit/a87b752cbc063e136f1a418ed5a7a57cc857fb30))
* stop counting coasting as easy riding ([97f369f](https://github.com/eschizoid/stride/commit/97f369f0c68226adf1513d751fae95a2c7aa3e80))
* sum real seconds in the pace intensity split, and call roc by name ([3271606](https://github.com/eschizoid/stride/commit/327160608b969d043fe4ffe53c020b7e2bf5e1f2))
* use the real EWMA factor so 42 and 7 days mean 42 and 7 days ([8d18965](https://github.com/eschizoid/stride/commit/8d189658b8f78fe78279ca4c865a8c10df091969))
* warn about an unconverged CTL until 90 days, not 42 ([35681d5](https://github.com/eschizoid/stride/commit/35681d5580c0f25d0d0293c9b6e09f1e08fbd43a))

## [0.3.0](https://github.com/eschizoid/stride/compare/v0.2.0...v0.3.0) (2026-08-05)


### Features

* decode all argv forms via OsStr.display (Windows UTF-16 support) ([3e3ce70](https://github.com/eschizoid/stride/commit/3e3ce70ccd9b6e80b90662281f8462ac2881669c))

## [0.2.0](https://github.com/eschizoid/stride/compare/v0.1.0...v0.2.0) (2026-08-04)


### ⚠ BREAKING CHANGES

* every machine JSON response is now wrapped. Success is {schema_version, data:<payload>}; errors are {schema_version, error:{code, message}} (the version number itself has moved since — the envelope key, not this entry, is the contract) — discriminate on which key is present. Deterministic (no timestamps), so golden comparisons stay stable. Tool callers read fields under .data and branch on .error.code. Human table output is unchanged. Made default (not gated) since the user base is still small. stride skill + e2e updated to the enveloped shape.
* rename prescriptions to plan across the CLI and data model

### Features

* add the pace-based load engine (rTSS/sTSS) as pure, tested math ([2af63fa](https://github.com/eschizoid/stride/commit/2af63fad7ae45bc6e08ccd69427877018c92cee9))
* aligned time+dist+alt stream triple for the pace engine ([938675d](https://github.com/eschizoid/stride/commit/938675d345a8e7aa40f724d8848b9e0e6662e3b5))
* auto-derive per-sport FTP so power-intensity applies to ANY sport ([5780fcc](https://github.com/eschizoid/stride/commit/5780fcc2df1de49f2a912068db6c3a0bd014a7b3))
* compare command — this period vs the one before it ([82ad357](https://github.com/eschizoid/stride/commit/82ad357932446b392d9c63de3dfa6f434bacd55e))
* complete a rest-day prescription without an activity id ([e195a92](https://github.com/eschizoid/stride/commit/e195a9267273bcdfeddacbf47b029a198699a0d2))
* count pace (rtss) load as measured/high-confidence in reports ([e6ec8f8](https://github.com/eschizoid/stride/commit/e6ec8f8cf85fee27bdd7e7bf740e911e3b3b68d0))
* Critical Power (CP/W') least-squares fit ([0578323](https://github.com/eschizoid/stride/commit/0578323269bf5c964df417e1b04cea2d4a2b4e93))
* expand doctor with confidence distribution + config completeness (P8) ([d9154a9](https://github.com/eschizoid/stride/commit/d9154a94e7efd5a570529f834a2aebaab5b768fc))
* fix pace-engine stop deflation and close review gaps ([fa10961](https://github.com/eschizoid/stride/commit/fa10961ab7040640d4e3971a7cab7ea6dc805e24))
* FTP is fully derived per sport — remove the config concept ([4bdfe88](https://github.com/eschizoid/stride/commit/4bdfe88f6085be42c437b6be0823850a9937d9ef))
* grade-adjusted pace algorithm (Minetti 2002) for runs ([0add058](https://github.com/eschizoid/stride/commit/0add0587a2d08b92a2d8ff9af6b7176023140e59))
* import Strava account exports, no API credentials needed ([95fc3e9](https://github.com/eschizoid/stride/commit/95fc3e9c6ee2bc4a2bbd66a34ff480b6d0ec4f5a))
* intensity from power for power rides (fixes hard-effort mislabel) ([6ca5bf4](https://github.com/eschizoid/stride/commit/6ca5bf4fab2e7fc27bf75b330674458333969577))
* mean-max power curve helper (best power at the duration ladder) ([7bd7fa4](https://github.com/eschizoid/stride/commit/7bd7fa459ccb62e540cb614277a911fba865020c))
* **new-compiler:** app.roc compiles clean on the new compiler — 0 errors ([179a56d](https://github.com/eschizoid/stride/commit/179a56d94526b05ea709c2d934feaf5cb016b082))
* pace rung in tss_ladder (power -&gt; pace -&gt; HR -&gt; RPE -&gt; RE) ([661259c](https://github.com/eschizoid/stride/commit/661259ce96e476b0719148872146c5f7a0e41c2f))
* pace scoring for swim + indoor — flat-speed path (ADR-0003 slice 3) ([0035fe9](https://github.com/eschizoid/stride/commit/0035fe9ef2d5780a9dd6df895f05b48250bbf32d))
* pace-intensity split for pace sports (pi_* from pace) ([830cd0e](https://github.com/eschizoid/stride/commit/830cd0e736a39560ed5d7c6ea85b664bcca0e873))
* per-sport HR zones (hr_z*_max_&lt;sport&gt;) with global fallback ([b639902](https://github.com/eschizoid/stride/commit/b639902cd6eda2ed535e31d17b36c7163bc34b35))
* per-sport pace-engine config keys (threshold_pace_&lt;sport&gt;, model_&lt;sport&gt;) ([ab7cf7e](https://github.com/eschizoid/stride/commit/ab7cf7e29d0085a97505fa50b890b18733824390))
* persist load confidence + stop labelling mixed load as TSS (P5) ([365336d](https://github.com/eschizoid/stride/commit/365336d5d6907e755c8fa8b3739d4ba9e8d3b9b8))
* power-based intensity across all surfaces, generic per-sport FTP ([92705cb](https://github.com/eschizoid/stride/commit/92705cb81cef1bea2dbe44563568f6685bfd8e23))
* power-curve command — power-duration curve + Critical Power ([f0ab7e3](https://github.com/eschizoid/stride/commit/f0ab7e3b752cd372083ccf271113d72000f9ba6f))
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
