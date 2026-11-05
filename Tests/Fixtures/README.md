# Regression fixtures

These files are test data, not a catalog of working services. Tests use intercepted requests or the loopback-only fixture server; they do not call the placeholder hosts or require real provider keys.

- `http-options.json`: synthetic POST JSON configuration covering option-specific language codes, errors and credential channels.
- `legacy-professional-services.json`: v2 configuration retained to verify backward compatibility with previously saved provider adapters.
- `context-regressions.json`: public fictional passages for evaluating context and writing preferences.
- `profile-generation-sample.txt` and `profile-generation-response.json`: a public, fictional conversation and a fixed structured profile response. They verify speaker attribution, grounded evidence, unchecked inferred terms, editable drafts, cancellation and atomic saving. The response is a protocol fixture, not evidence of real model quality.
- Live caption WebSocket checks use `scripts/mock-caption-service.py` with synthetic PCM. The fixture verifies both Realtime 24 kHz and Alibaba Qwen 16 kHz sessions, unique Qwen event IDs, replacement previews, finish/drain, authentication and rejected redirects, then returns one fixed public sentence. It is not a speech recognition model and should only receive public test audio. Audio generated for native UI checks stays in the ignored `.build/` directory.

User configuration format is documented in [`docs/services.md`](../../docs/services.md). The application offers generic Custom AI and Custom HTTP Translation configuration, with Apple Translate as the default.
