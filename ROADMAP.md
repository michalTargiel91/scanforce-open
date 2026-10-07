# Roadmap

This is where ScanForce Open is heading. It is a direction, not a schedule:
there are no dates, and items in **Next** and **Later** can change or be
dropped based on what users and provider builders report. The
[changelog](CHANGELOG.md) records what actually shipped.

Influence it: comment on or upvote [ideas in Discussions](https://github.com/michalTargiel91/scanforce-open/discussions/categories/ideas),
or open a [feature request](https://github.com/michalTargiel91/scanforce-open/issues/new/choose).

## Now (1.0.x)

* **Make first use easy.** Quickstart, troubleshooting, tested examples (Flows,
  Apex, demo kit), and a reference provider that runs in a container.
* **Help provider builders.** Conformance checker with actionable failures
  and a CI recipe.
* **Learn from the first external installations** and custom providers, and
  fix what gets in their way.

## Next (candidates)

* **Package-based installation**: an unlocked package without a namespace,
  next to the source install. See the [distribution analysis](docs/distribution.md)
  and its open questions.
* **More provider examples**, for example a starter in another language,
  if provider builders ask for one.
* **Review integrations**: smoother Review Required handling in Flow, such as
  notification patterns and examples.

## Later (under consideration)

* **Richer field mappings**: for example line items to child records, or
  lookups. Only with a design that keeps user-mode access and strict
  conversion.
* **AppExchange distribution**, only if there is clear demand. It requires a
  namespace and a security review.
* **`/connect/v2`**, only if a needed capability cannot be added compatibly
  to `/connect/v1`.

## Not planned

* OCR or AI models running inside Salesforce. Extraction belongs to providers.
* Provider-specific code paths, payloads or states in the Salesforce app.
* Telemetry or usage tracking in the app.
* A hosted control plane or marketplace run by the project.
