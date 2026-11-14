# Security Policy

NRVL Network handles router credentials and can change network settings, so security reports are taken seriously.

## Reporting a vulnerability

**Please do not open a public issue.**

Report privately through GitHub: go to the repository's **Security** tab → **Report a vulnerability** ([direct link](https://github.com/princenrvl/nrvl-network/security/advisories/new)).

Include, where you can:
- what is affected and how to reproduce it,
- the app version and macOS version,
- the impact you expect.

Do not include real credentials, and do not test against networks you are not authorised to administer.

## What to expect

- Acknowledgement within 7 days.
- An assessment and, if confirmed, a fix plan. You will be kept informed.
- Credit in the release notes, unless you prefer otherwise.

## Supported versions

The project is in early preview. Only the latest release and the `main` branch receive security fixes.

## Scope

In scope: the app and its source in this repository — for example credential handling, TLS pinning, the audit log, parsing of data received from the network, and the change pipeline.

Out of scope: vulnerabilities in routers or other third-party devices themselves (report those to their vendors).

## More

How the app protects credentials, what it sends on the network, and its known limits are described in [docs/SECURITY.md](docs/SECURITY.md).
