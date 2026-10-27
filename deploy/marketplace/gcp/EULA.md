# WindyFlo — End User License Agreement (GCP Marketplace listing)

WindyFlo is licensed under the **Apache License, Version 2.0** (see `LICENSE.md` at the repository
root). For Google Cloud Marketplace you must attach terms to the listing. You have two options:

## Option A (simplest) — use Google's default marketplace terms

In Producer Portal → the listing's **Legal** section, Google offers default terms for
free/BYOL products in many cases — check what's presented for your listing type. Recommended for a
first BYOL/Free listing, same call as the Azure Standard Contract and AWS Standard Contract.

## Option B — supply your own terms

Provide a Terms of Service URL / document. For an Apache-2.0 product, the terms typically state:

> This software (WindyFlo) is provided under the Apache License 2.0. A copy of the license is
> included with the software and is available at http://www.apache.org/licenses/LICENSE-2.0.
> The software is provided "AS IS", without warranty of any kind, express or implied. Your use of
> the deployed software, any data you process with it, and any third-party AI/model APIs you
> connect (e.g. OpenAI, Anthropic, Google Vertex AI) are your responsibility and subject to those
> providers' own terms. [Publisher] provides support as described in the listing's Support section.

Replace `[Publisher]` and have counsel review before publishing. This is the same cloud-agnostic
Apache-2.0 language used in [../azure/EULA.md](../azure/EULA.md) and [../aws/EULA.md](../aws/EULA.md)
— keep all three in sync if the wording changes.

## Privacy policy (required regardless)

Producer Portal requires a **Privacy Policy URL**. WindyFlo self-hosts in the buyer's own GKE
cluster, so the publisher does not process buyer data by default — but a privacy URL is still
mandatory. Use `https://windyflo.com/privacy-policy` (a real page; windyflo.com/privacy is a 404 — the site is Framer and answers HTTP 200 for unknown paths, so check pages in a browser, not with curl) describing what (if any) telemetry the
app emits. If the UI ships Firebase/analytics (VITE\_\* baked at build), disclose it there — same
disclosure obligation as the Azure and AWS listings.
