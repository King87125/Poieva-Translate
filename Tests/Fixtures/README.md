# Regression fixtures

These files are test data, not a catalog of working services. Tests use intercepted requests or the loopback-only fixture server; they do not call the placeholder hosts or require real provider keys.

- `http-options.json`: synthetic POST JSON configuration covering option-specific language codes, errors and credential channels.
- `legacy-professional-services.json`: v2 configuration retained to verify backward compatibility with previously saved provider adapters.
- `context-regressions.json`: public fictional passages for evaluating context and writing preferences.

User configuration format is documented in [`docs/services.md`](../../docs/services.md). The application offers generic Custom AI and Custom HTTP Translation configuration, with Apple Translate as the default.
