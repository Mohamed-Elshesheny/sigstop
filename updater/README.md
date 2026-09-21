# updater/

The one file in this directory is the update feed, and this directory is the whole of
what GitHub Pages serves for this repository.

`SUFeedURL` in `app/Resources/Info.plist` is
`https://mohamed-elshesheny.github.io/sigstop/appcast.xml`. That is this folder's
`appcast.xml`, deployed by `.github/workflows/pages.yml` on every push to `main`.

It is checked in rather than generated at deploy time on purpose. The EdDSA signature on
each enclosure is made with a private key that never leaves the maintainer's login
keychain, so no CI job can produce one, and a feed a runner could rewrite would defeat
the thing the signature is for.

Regenerate it with `make release`, which runs `Scripts/appcast.sh`. Do not hand-edit it:
an edit after signing invalidates the signature, and the app will refuse the update
rather than warn you.
