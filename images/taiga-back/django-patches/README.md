# Django 3.2 security patches

Taiga 6.10 is pinned to Django 3.2, out of upstream support since April 2024. Debian keeps Django 3.2 in bookworm
and backports the security fixes to it. This directory holds those patches, applied in the image to the installed
Django 3.2.25 (only their `django/` part: tests and documentation are not installed).

## Origin

- Debian source package `python-django` `3:3.2.25-0+deb12u6` (bookworm-security), `debian/patches/`.
- `python-django_3.2.25-0+deb12u6.dsc`, signed by Chris Lamb (Debian Developer, key
  `C2FE 4BD2 71C1 39B8 6C53 3E46 1E95 3E27 D431 1E58`, in the `debian-keyring`); it lists
  `python-django_3.2.25-0+deb12u6.debian.tar.xz` with SHA-256
  `aebf754a74097717c05448e0e4b8181333c2194e675811679577f2761c1fe92c`.
- The patches apply to `python-django_3.2.25.orig.tar.gz`, which is the PyPI sdist `Django-3.2.25.tar.gz`
  (SHA-256 `7ca38a78654aee72378594d63e51636c04b8e28574f5505dff630895b5472777`, also pinned in
  `../requirements.txt`).

The files are copied unchanged, in the order of Debian's `series`, except the packaging-only ones, left out:
`0001-disable-sources-in-sphinxdoc.diff`, `0002-use_debian_geoip_database_as_default.diff`,
`0004-Use-locally-installed-documentation-sources.patch`,
`0004-Set-the-default-shebang-to-new-projects-to-use-Pytho.patch` and
`0005-Use-usr-bin-env-python3-shebang-for-django-admin.py.patch`.

`9001-CVE-2026-8404.patch` is ours: a backport of django/django@d618d7ae4f (Cache-Control directives matched
case-insensitively in `UpdateCacheMiddleware`), which Debian has not released for 3.2 yet. Taiga uses `cache_page`.

## Checked

- Django's whole test suite (SQLite) passes the same on Django 3.2.25 with and without these patches, plus the
  regression tests the patches add.
- Taiga's whole test suite (1749 tests, on PostgreSQL 13 and RabbitMQ, as its CI runs it) passes with and without
  these patches.
- The `django/` part of every patch applies to the Django 3.2.25 wheel installed by `requirements.txt`; the image
  build fails if one stops applying.

## Updating

When Debian publishes a new `python-django` security release for bookworm, download its `.dsc` and
`.debian.tar.xz` from `https://deb.debian.org/debian-security/pool/updates/main/p/python-django/`, check the
signature (`gpgv --keyring /usr/share/keyrings/debian-keyring.gpg *.dsc`) and the SHA-256 of the tarball against
the `.dsc`, copy the new patches here with `series`, update this file and `../.trivyignore`, and rebuild.
