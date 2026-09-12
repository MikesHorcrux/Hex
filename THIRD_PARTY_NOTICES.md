# Third-party notices

Hex's MIT license applies to Hex's own code. Dependencies and optional tools retain their original
licenses and notices. The package versions below come from the committed SwiftPM lockfile. License
texts are copied unchanged from those resolved checkouts, including embedded crypto-library notices.

| Component | Version | Upstream | Notices |
| --- | --- | --- | --- |
| eventsource | 1.5.1 | [https://github.com/mattt/EventSource.git](https://github.com/mattt/EventSource.git) | [License files](ThirdPartyLicenses/eventsource/) |
| mlx-swift | 0.31.6 | [https://github.com/ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) | [License files](ThirdPartyLicenses/mlx-swift/) |
| mlx-swift-lm | 3.31.4 | [https://github.com/ml-explore/mlx-swift-lm.git](https://github.com/ml-explore/mlx-swift-lm.git) | [License files](ThirdPartyLicenses/mlx-swift-lm/) |
| swift-argument-parser | 1.8.2 | [https://github.com/apple/swift-argument-parser](https://github.com/apple/swift-argument-parser) | [License files](ThirdPartyLicenses/swift-argument-parser/) |
| swift-asn1 | 1.7.2 | [https://github.com/apple/swift-asn1.git](https://github.com/apple/swift-asn1.git) | [License files](ThirdPartyLicenses/swift-asn1/) |
| swift-collections | 1.6.0 | [https://github.com/apple/swift-collections.git](https://github.com/apple/swift-collections.git) | [License files](ThirdPartyLicenses/swift-collections/) |
| swift-crypto | 4.5.2 | [https://github.com/apple/swift-crypto.git](https://github.com/apple/swift-crypto.git) | [License files](ThirdPartyLicenses/swift-crypto/) |
| swift-huggingface | 0.10.1 | [https://github.com/huggingface/swift-huggingface.git](https://github.com/huggingface/swift-huggingface.git) | [License files](ThirdPartyLicenses/swift-huggingface/) |
| swift-jinja | 2.5.0 | [https://github.com/huggingface/swift-jinja.git](https://github.com/huggingface/swift-jinja.git) | [License files](ThirdPartyLicenses/swift-jinja/) |
| swift-numerics | 1.1.1 | [https://github.com/apple/swift-numerics](https://github.com/apple/swift-numerics) | [License files](ThirdPartyLicenses/swift-numerics/) |
| swift-syntax | 603.0.2 | [https://github.com/swiftlang/swift-syntax.git](https://github.com/swiftlang/swift-syntax.git) | [License files](ThirdPartyLicenses/swift-syntax/) |
| swift-transformers | 1.3.3 | [https://github.com/huggingface/swift-transformers.git](https://github.com/huggingface/swift-transformers.git) | [License files](ThirdPartyLicenses/swift-transformers/) |
| yyjson | 0.12.0 | [https://github.com/ibireme/yyjson.git](https://github.com/ibireme/yyjson.git) | [License files](ThirdPartyLicenses/yyjson/) |
| node (optional runtime) | 24.20.0 | [Upstream license](https://raw.githubusercontent.com/nodejs/node/v24.20.0/LICENSE) | [License](ThirdPartyLicenses/node/LICENSE) |
| peekaboo (optional runtime) | 4.3.3 | [Upstream license](https://raw.githubusercontent.com/openclaw/Peekaboo/v4.3.3/LICENSE) | [License](ThirdPartyLicenses/peekaboo/LICENSE) |
| playwright-mcp (optional runtime) | 0.0.80 | [Upstream license](https://raw.githubusercontent.com/microsoft/playwright-mcp/v0.0.80/LICENSE) | [License](ThirdPartyLicenses/playwright-mcp/LICENSE) |

| playwright (optional runtime) | 1.63.0-alpha-2026-08-31 | [npm distribution](https://registry.npmjs.org/playwright/-/playwright-1.63.0-alpha-2026-08-31.tgz) | [Notices](ThirdPartyLicenses/playwright/) |
| playwright-core (optional runtime) | 1.63.0-alpha-2026-08-31 | [npm distribution](https://registry.npmjs.org/playwright-core/-/playwright-core-1.63.0-alpha-2026-08-31.tgz) | [Notices](ThirdPartyLicenses/playwright-core/) |

Optional runtimes are downloaded only when their capability is installed and are stored outside
Hex.app. Node includes additional third-party notices in its LICENSE. Playwright downloads a browser;
retain that distribution's own license and credits files when redistributing it. Model weights are
not included in this repository; each downloaded model has separate license terms.

Hex uses Peekaboo as a screen-control tool. It does not embed OpenClaw's agent runtime. Architecture
research references Codex, OpenClaw, Goose, and other harnesses; these references do not imply
partnership or endorsement. Do not remove upstream notices when redistributing dependencies.

Update this inventory and license copies whenever dependency or managed-runtime versions change.
