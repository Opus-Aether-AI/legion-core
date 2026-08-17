# Changelog

## [0.23.4](https://github.com/Opus-Aether-AI/legion-core/compare/v0.23.3...v0.23.4) (2026-08-17)


### Fixed

* **consumer-update:** scope the registry token to the job, not one step ([#151](https://github.com/Opus-Aether-AI/legion-core/issues/151)) ([7afad66](https://github.com/Opus-Aether-AI/legion-core/commit/7afad66b4de05edd03110e1bd36e1d400c06a06b))
* **consumer-update:** stop requesting a permission callers cannot grant ([#149](https://github.com/Opus-Aether-AI/legion-core/issues/149)) ([74a8b67](https://github.com/Opus-Aether-AI/legion-core/commit/74a8b67d1754ab7806b5cb250b056f6e124e63e7))

## [0.23.3](https://github.com/Opus-Aether-AI/legion-core/compare/v0.23.2...v0.23.3) (2026-08-16)


### Fixed

* **learning:** repair the self-improvement loop's dead gates ([#146](https://github.com/Opus-Aether-AI/legion-core/issues/146)) ([442d512](https://github.com/Opus-Aether-AI/legion-core/commit/442d512ddb2f4928656f1ef28ff9a09185e9f533))

## [0.23.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.23.1...v0.23.2) (2026-08-14)


### Fixed

* **setup:** stop an empty marketplace resolve from wiping the Cursor bridge ([#143](https://github.com/Opus-Aether-AI/legion-core/issues/143)) ([0f1e8d9](https://github.com/Opus-Aether-AI/legion-core/commit/0f1e8d98552b8f6ba9eddcfac426e81eb2269626))

## [0.23.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.23.0...v0.23.1) (2026-08-13)


### Fixed

* **observability:** reject SKILL.md frontmatter that is not valid YAML ([#139](https://github.com/Opus-Aether-AI/legion-core/issues/139)) ([5f20671](https://github.com/Opus-Aether-AI/legion-core/commit/5f2067113e311036cda87effbc55c0d7964231e3))

## [0.23.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.22.2...v0.23.0) (2026-08-12)


### Added

* **router:** make every harness primary or child ([#136](https://github.com/Opus-Aether-AI/legion-core/issues/136)) ([9570b11](https://github.com/Opus-Aether-AI/legion-core/commit/9570b116fb89e86bd366f601c7c9493599386c07))


### Fixed

* **workflow:** stop primary sessions on convergence ([#137](https://github.com/Opus-Aether-AI/legion-core/issues/137)) ([e8dbc49](https://github.com/Opus-Aether-AI/legion-core/commit/e8dbc49ebdc9920781c11a601c0f2cee169ed7dd))

## [0.22.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.22.1...v0.22.2) (2026-08-11)


### Fixed

* **observability:** expose routing classification gaps ([#133](https://github.com/Opus-Aether-AI/legion-core/issues/133)) ([deb7f33](https://github.com/Opus-Aether-AI/legion-core/commit/deb7f33fcff62dc78e5160e80fd96470ac590130))

## [0.22.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.22.0...v0.22.1) (2026-08-10)


### Performance

* bound learning and harden fanout runtime ([#126](https://github.com/Opus-Aether-AI/legion-core/issues/126)) ([167e9fa](https://github.com/Opus-Aether-AI/legion-core/commit/167e9fa21a78c49eb8d87f461545a49b3e631802))

## [0.22.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.21.1...v0.22.0) (2026-08-10)


### Added

* **core:** enable cross-harness handoffs with shared learning ([#125](https://github.com/Opus-Aether-AI/legion-core/issues/125)) ([878890a](https://github.com/Opus-Aether-AI/legion-core/commit/878890a7213bbaa648fc9a5ed3d0be859fc752b0))


### Fixed

* **router:** handle OpenCode 1.3 error events ([#128](https://github.com/Opus-Aether-AI/legion-core/issues/128)) ([764b9aa](https://github.com/Opus-Aether-AI/legion-core/commit/764b9aae90d5526d093fa0869177c0b673af0156))
* **setup:** authenticate the latest-release lookup for private repos ([#124](https://github.com/Opus-Aether-AI/legion-core/issues/124)) ([8c37803](https://github.com/Opus-Aether-AI/legion-core/commit/8c378036d85f1ddbc01b5cccbce153bb6b34636b))

## [0.21.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.21.0...v0.21.1) (2026-08-08)


### Fixed

* **router:** honor a non-approving review verdict from a failed reviewer ([#122](https://github.com/Opus-Aether-AI/legion-core/issues/122)) ([2279ded](https://github.com/Opus-Aether-AI/legion-core/commit/2279dedb6c8dd9c3fe5e75555b4b7847af3bcbed))

## [0.21.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.20.1...v0.21.0) (2026-08-08)


### Added

* **learning:** close the self-improvement loop ([#120](https://github.com/Opus-Aether-AI/legion-core/issues/120)) ([cdbfe11](https://github.com/Opus-Aether-AI/legion-core/commit/cdbfe111d28b2d816de11208fa6577d683b1effe))

## [0.20.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.20.0...v0.20.1) (2026-08-05)


### Fixed

* **state:** tolerate contended lock acquisition ([#113](https://github.com/Opus-Aether-AI/legion-core/issues/113)) ([59d991a](https://github.com/Opus-Aether-AI/legion-core/commit/59d991a9ef04932034f4703c3894fbfa872db0a9))

## [0.20.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.19.1...v0.20.0) (2026-08-05)


### Added

* **learning:** add evidence-linked self-improvement loop ([#115](https://github.com/Opus-Aether-AI/legion-core/issues/115)) ([a547dba](https://github.com/Opus-Aether-AI/legion-core/commit/a547dbad8b4167242504438f6e6b01871bafc42b))


### Fixed

* complete runtime surface and preserve trace identity ([#109](https://github.com/Opus-Aether-AI/legion-core/issues/109)) ([3334d89](https://github.com/Opus-Aether-AI/legion-core/commit/3334d89539540382d6ef74713cbac70040a47fe2))
* **learning:** remediate evidence review findings ([#116](https://github.com/Opus-Aether-AI/legion-core/issues/116)) ([003ccd4](https://github.com/Opus-Aether-AI/legion-core/commit/003ccd4ea8405dcc88ebe051047b57866360ce5c))
* **release:** avoid retrying repaired GitHub releases ([#112](https://github.com/Opus-Aether-AI/legion-core/issues/112)) ([1ed494e](https://github.com/Opus-Aether-AI/legion-core/commit/1ed494e913371c721d1766a8802e89e450c76f92))
* **release:** reconcile tagged Release PR labels ([#118](https://github.com/Opus-Aether-AI/legion-core/issues/118)) ([05f6e5f](https://github.com/Opus-Aether-AI/legion-core/commit/05f6e5f851d953c72859dbb4fe5f79dfae64e500))
* **release:** recover publication and notify consumers ([#111](https://github.com/Opus-Aether-AI/legion-core/issues/111)) ([5819db5](https://github.com/Opus-Aether-AI/legion-core/commit/5819db55f3a774ff6b74b3e3878f0321fbd1f702))
* **release:** target renamed Nidavellir consumer ([#114](https://github.com/Opus-Aether-AI/legion-core/issues/114)) ([26395f3](https://github.com/Opus-Aether-AI/legion-core/commit/26395f38d221b69b225ac34c11542b3f65a47993))

## [0.19.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.19.0...v0.19.1) (2026-07-31)


### Fixed

* harden release and update controls ([#108](https://github.com/Opus-Aether-AI/legion-core/issues/108)) ([bf17a30](https://github.com/Opus-Aether-AI/legion-core/commit/bf17a308d8cebb42db1ba59606d19ad10e9a2457))

## [0.19.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.18.2...v0.19.0) (2026-07-31)


### Added

* **release:** recover Legion defaults and guard titles ([#106](https://github.com/Opus-Aether-AI/legion-core/issues/106)) ([1e710b5](https://github.com/Opus-Aether-AI/legion-core/commit/1e710b5504c149b364a5f1a48670c72ce167bc4a))

## [0.18.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.18.1...v0.18.2) (2026-07-30)


### Fixed

* **release:** gate publish on validate + legion-ci being green ([#103](https://github.com/Opus-Aether-AI/legion-core/issues/103)) ([1cf00fe](https://github.com/Opus-Aether-AI/legion-core/commit/1cf00fe8719838add533b223831783d187fba717))

## [0.18.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.18.0...v0.18.1) (2026-07-29)


### Fixed

* **router:** delegate lifecycle, diff scope and route arg parity ([#99](https://github.com/Opus-Aether-AI/legion-core/issues/99)) ([eb0c03c](https://github.com/Opus-Aether-AI/legion-core/commit/eb0c03ca211770229f3303d664f73ad46e6ce0c4))
* **router:** isolate claude runs, unblock ordinary prose, move opus to 5 ([#100](https://github.com/Opus-Aether-AI/legion-core/issues/100)) ([26b2248](https://github.com/Opus-Aether-AI/legion-core/commit/26b22481a16221da5999359fa1e9bcdbd1383182))


### Changed

* **models:** resolve all model ids from config, never hardcode ([#98](https://github.com/Opus-Aether-AI/legion-core/issues/98)) ([963f15e](https://github.com/Opus-Aether-AI/legion-core/commit/963f15e78a540047007c8dcfd88b4f4b20bf127b))

## [0.18.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.17.1...v0.18.0) (2026-07-20)


### Added

* **orchestrate:** enforce explicit ADW lifecycle ([#96](https://github.com/Opus-Aether-AI/legion-core/issues/96)) ([9e9ddce](https://github.com/Opus-Aether-AI/legion-core/commit/9e9ddce6dfb22634a1937cf9f9c44768a1d694bb))

## [0.17.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.17.0...v0.17.1) (2026-07-19)


### Fixed

* **install:** read plugin list after clone sync + auto-wire opencode ([#94](https://github.com/Opus-Aether-AI/legion-core/issues/94)) ([a219049](https://github.com/Opus-Aether-AI/legion-core/commit/a219049466a308dbf4013b45682a1ed625c35411))

## [0.17.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.16.0...v0.17.0) (2026-07-19)


### Added

* harness-generic core — opencode/hermes, frontend Opus/Fable routing, storage fixes ([#91](https://github.com/Opus-Aether-AI/legion-core/issues/91)) ([d9619af](https://github.com/Opus-Aether-AI/legion-core/commit/d9619affb8ae80a64a23a56d69f5727a8899f6b6))

## [0.16.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.15.0...v0.16.0) (2026-07-14)


### Added

* harden legion-run self-learning ([#88](https://github.com/Opus-Aether-AI/legion-core/issues/88)) ([87801c4](https://github.com/Opus-Aether-AI/legion-core/commit/87801c404d43ccf7d5a080533b472e1b48b4064b))

## [0.15.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.14.1...v0.15.0) (2026-07-09)


### Added

* add legion-run direct benchmark ([#86](https://github.com/Opus-Aether-AI/legion-core/issues/86)) ([f572694](https://github.com/Opus-Aether-AI/legion-core/commit/f57269427ba8790b3d375e695b3a14a5cfdf90ee))


### Documentation

* **seo:** align messaging to "the AI-agent stack under the hood" + hermetic router tests ([#84](https://github.com/Opus-Aether-AI/legion-core/issues/84)) ([cd5200d](https://github.com/Opus-Aether-AI/legion-core/commit/cd5200dfefcf35fbea8b5ca2fe45ce055da91031))

## [0.14.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.14.0...v0.14.1) (2026-07-08)


### Fixed

* make legion-delegate robust under non-interactive stdio ([#82](https://github.com/Opus-Aether-AI/legion-core/issues/82)) ([fac6cf0](https://github.com/Opus-Aether-AI/legion-core/commit/fac6cf0de7946e49c9a83875842e5e0c17e15e25))

## [0.14.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.13.1...v0.14.0) (2026-07-08)


### Added

* support multiple legion-run plan files ([#80](https://github.com/Opus-Aether-AI/legion-core/issues/80)) ([48e8c76](https://github.com/Opus-Aether-AI/legion-core/commit/48e8c76f2a3a714eba614b2b4cb5c2d21be4e249))

## [0.13.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.13.0...v0.13.1) (2026-07-06)


### Fixed

* harden legion run orchestration ([#79](https://github.com/Opus-Aether-AI/legion-core/issues/79)) ([22225f5](https://github.com/Opus-Aether-AI/legion-core/commit/22225f550b5f4aaa5bda0a78725ae4dc630d1b0a))


### Documentation

* explain legion usage modes ([#77](https://github.com/Opus-Aether-AI/legion-core/issues/77)) ([cbdb6bb](https://github.com/Opus-Aether-AI/legion-core/commit/cbdb6bb2f25300023d7a63eed5af52b9f829955d))

## [0.13.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.12.0...v0.13.0) (2026-07-05)


### Added

* generate domain plugin TDD slices from briefs ([#75](https://github.com/Opus-Aether-AI/legion-core/issues/75)) ([605aad3](https://github.com/Opus-Aether-AI/legion-core/commit/605aad3d2ba0e0227e9eca1179082fea896cf377))

## [0.12.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.11.1...v0.12.0) (2026-07-05)


### Added

* enforce domain plugin pipeline runner ([#72](https://github.com/Opus-Aether-AI/legion-core/issues/72)) ([14ca173](https://github.com/Opus-Aether-AI/legion-core/commit/14ca1733e29a612751494780d02c199728aced73))

## [0.11.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.11.0...v0.11.1) (2026-07-05)


### Fixed

* **router:** centralize model defaults ([#70](https://github.com/Opus-Aether-AI/legion-core/issues/70)) ([857ffe3](https://github.com/Opus-Aether-AI/legion-core/commit/857ffe3ee57da2590d5a6df353502cf0daa85f49))


### Documentation

* **enterprise:** enterprise offering for VPC, SDLC gates, and AWS WAF ([#68](https://github.com/Opus-Aether-AI/legion-core/issues/68)) ([bbda644](https://github.com/Opus-Aether-AI/legion-core/commit/bbda644bdf53e12daeafd246efa3ce7a7f61033f))

## [0.11.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.10.2...v0.11.0) (2026-07-05)


### Added

* **code-intel:** add optional diagnostic gate ([#65](https://github.com/Opus-Aether-AI/legion-core/issues/65)) ([71efcca](https://github.com/Opus-Aether-AI/legion-core/commit/71efcca87c2e7072933e2217ff5b9bbea54bae84))

## [0.10.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.10.1...v0.10.2) (2026-07-02)


### Fixed

* **observability:** pin best-model live metering ([#62](https://github.com/Opus-Aether-AI/legion-core/issues/62)) ([c84daba](https://github.com/Opus-Aether-AI/legion-core/commit/c84daba0588b52dc12abb2d63506dd2d31d75fd1))

## [0.10.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.10.0...v0.10.1) (2026-07-02)


### Documentation

* **enterprise:** add ENTERPRISE.md; drop awspex ignore bleed-through ([#60](https://github.com/Opus-Aether-AI/legion-core/issues/60)) ([cd1cfa4](https://github.com/Opus-Aether-AI/legion-core/commit/cd1cfa4a318f8407774db589875d1b199fdc2fac))

## [0.10.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.9.2...v0.10.0) (2026-07-02)


### Added

* **observability:** add heldout live bench lane ([#54](https://github.com/Opus-Aether-AI/legion-core/issues/54)) ([d92a2b0](https://github.com/Opus-Aether-AI/legion-core/commit/d92a2b0fc45fe119b6758a9468721cf7a9ec8dc1))

## [0.9.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.9.1...v0.9.2) (2026-06-27)


### Documentation

* **readme:** fix header badge row and shorten install one-liner ([#57](https://github.com/Opus-Aether-AI/legion-core/issues/57)) ([0b6a8e9](https://github.com/Opus-Aether-AI/legion-core/commit/0b6a8e9850c9b2c058ad32f0f36e60ca71105761))

## [0.9.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.9.0...v0.9.1) (2026-06-26)


### Fixed

* **release:** publish legion through opus aether scope ([#52](https://github.com/Opus-Aether-AI/legion-core/issues/52)) ([1d0c94d](https://github.com/Opus-Aether-AI/legion-core/commit/1d0c94df8dcf0f6c1f6cdbe552118f9dd5c5b3e6))

## [0.9.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.8.2...v0.9.0) (2026-06-26)


### Added

* **observability:** add legion-bench workbench and stable gates ([#47](https://github.com/Opus-Aether-AI/legion-core/issues/47)) ([5b2c7c3](https://github.com/Opus-Aether-AI/legion-core/commit/5b2c7c324957a55e695d3936f5d71a035aadfe97))

## [0.8.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.8.1...v0.8.2) (2026-06-26)


### Fixed

* **intake:** make AFK lane Legion-generic ([#49](https://github.com/Opus-Aether-AI/legion-core/issues/49)) ([29fa9fe](https://github.com/Opus-Aether-AI/legion-core/commit/29fa9fe548bc09705ebce7b8698423fd6aabe3b0))

## [0.8.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.8.0...v0.8.1) (2026-06-26)


### Documentation

* **identity:** improve Legion Core banner ([#46](https://github.com/Opus-Aether-AI/legion-core/issues/46)) ([bdbe293](https://github.com/Opus-Aether-AI/legion-core/commit/bdbe293082c64fab07793a42b63fb2b02de02958))

## [0.8.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.7.3...v0.8.0) (2026-06-26)


### Added

* **observability:** auto-record session feedback ([#44](https://github.com/Opus-Aether-AI/legion-core/issues/44)) ([759e054](https://github.com/Opus-Aether-AI/legion-core/commit/759e054c1819fe8967e43f0d09c16b019f54d1ad))

## [0.7.3](https://github.com/Opus-Aether-AI/legion-core/compare/v0.7.2...v0.7.3) (2026-06-24)


### Fixed

* resolve open legion-core issues ([#40](https://github.com/Opus-Aether-AI/legion-core/issues/40)) ([b08cee0](https://github.com/Opus-Aether-AI/legion-core/commit/b08cee029ec732e42e6f20c9efb2c0184dc6b7c6))

## [0.7.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.7.1...v0.7.2) (2026-06-23)


### Changed

* **observability:** load dynamic context profile groups ([#34](https://github.com/Opus-Aether-AI/legion-core/issues/34)) ([97e9d59](https://github.com/Opus-Aether-AI/legion-core/commit/97e9d59e9bfb71992a1b2dbc2c849ecd7e06984f))

## [0.7.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.7.0...v0.7.1) (2026-06-23)


### Fixed

* **router:** guard forced proxy configuration ([c8aee61](https://github.com/Opus-Aether-AI/legion-core/commit/c8aee610505d0060fa36e7999a1c5abbcfb1f1f0))

## [0.7.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.6.0...v0.7.0) (2026-06-22)


### Added

* **observability:** add `legion-share gate` to enforce the codex balance ([#29](https://github.com/Opus-Aether-AI/legion-core/issues/29)) ([4372be0](https://github.com/Opus-Aether-AI/legion-core/commit/4372be075f1f4feaa96b92b97f92976fb97bab9a)), closes [#25](https://github.com/Opus-Aether-AI/legion-core/issues/25)

## [0.6.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.5.0...v0.6.0) (2026-06-22)


### Added

* **router:** sandbox/worktree lifecycle — setup + teardown ([#23](https://github.com/Opus-Aether-AI/legion-core/issues/23)) ([4a20a27](https://github.com/Opus-Aether-AI/legion-core/commit/4a20a2783cbb94006673df8fc6670d2cc98b8089))

## [0.5.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.4.0...v0.5.0) (2026-06-22)


### Added

* **intake:** GitHub issue/label AFK agent intake lane (P10 loop edge) ([#19](https://github.com/Opus-Aether-AI/legion-core/issues/19)) ([bca383e](https://github.com/Opus-Aether-AI/legion-core/commit/bca383ebfa87cba16400175de10b6037a8a26bcd))

## [0.4.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.3.1...v0.4.0) (2026-06-22)


### Added

* **router:** optional container/VM sandbox via @ai-hero/sandcastle (P16) ([#18](https://github.com/Opus-Aether-AI/legion-core/issues/18)) ([1cb7b6d](https://github.com/Opus-Aether-AI/legion-core/commit/1cb7b6de30f889f5509d878a329e6cc8477eb7a1))

## [0.3.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.3.0...v0.3.1) (2026-06-22)


### Fixed

* resolve open legion-core issues ([#1](https://github.com/Opus-Aether-AI/legion-core/issues/1) [#2](https://github.com/Opus-Aether-AI/legion-core/issues/2) [#3](https://github.com/Opus-Aether-AI/legion-core/issues/3) [#7](https://github.com/Opus-Aether-AI/legion-core/issues/7)) ([#17](https://github.com/Opus-Aether-AI/legion-core/issues/17)) ([41f96fa](https://github.com/Opus-Aether-AI/legion-core/commit/41f96fac780a44821a94fa40121b3f274d57f03f))

## [0.3.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.2.0...v0.3.0) (2026-06-21)


### Added

* skill taxonomy + AGENTS/CONTEXT + opt-in cron (anti-bloat) ([#15](https://github.com/Opus-Aether-AI/legion-core/issues/15)) ([8144551](https://github.com/Opus-Aether-AI/legion-core/commit/8144551e4ca689633943ee6ef74ab13d2cdcf6b6))

## [0.2.0](https://github.com/Opus-Aether-AI/legion-core/compare/v0.1.3...v0.2.0) (2026-06-21)


### Added

* **package:** publish legion-core to GitHub Packages (npm, private) ([#11](https://github.com/Opus-Aether-AI/legion-core/issues/11)) ([c9b4581](https://github.com/Opus-Aether-AI/legion-core/commit/c9b4581e7ce430422ea96d281e8be6c598b3272c))

## [0.1.3](https://github.com/Opus-Aether-AI/legion-core/compare/v0.1.2...v0.1.3) (2026-06-21)


### Fixed

* **engine:** close heal-gate bypass, finish rename, portability + robustness ([#10](https://github.com/Opus-Aether-AI/legion-core/issues/10)) ([bff188f](https://github.com/Opus-Aether-AI/legion-core/commit/bff188fb02cc2a310e1e35d9215d93a909983b5b))

## [0.1.2](https://github.com/Opus-Aether-AI/legion-core/compare/v0.1.1...v0.1.2) (2026-06-21)


### Fixed

* **doctor:** locate costs/telemetry/bridge files vendor-aware ([#6](https://github.com/Opus-Aether-AI/legion-core/issues/6)) ([a3af601](https://github.com/Opus-Aether-AI/legion-core/commit/a3af601beabdee01b21b3b4e1d66c96c272070b9))

## [0.1.1](https://github.com/Opus-Aether-AI/legion-core/compare/v0.1.0...v0.1.1) (2026-06-21)


### Fixed

* **eval:** recalibrate trigger datasets to the legion-core skill surface ([51cda21](https://github.com/Opus-Aether-AI/legion-core/commit/51cda21f7f6ea2e6cf94fa41c977982ff406e33c))
* **install:** point the minimal profile at core plugins (was opus-core) ([0f30122](https://github.com/Opus-Aether-AI/legion-core/commit/0f30122a03675c6deff5cd079fec1fa50aa48076))
