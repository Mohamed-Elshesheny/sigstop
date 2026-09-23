# updater/

Two files live here: `appcast.xml`, the update feed, and this README. The directory is the whole
of what GitHub Pages serves for this repository, so both are served.

`SUFeedURL` in `app/Resources/Info.plist` is
`https://mohamed-elshesheny.github.io/sigstop/appcast.xml`. That is this folder's
`appcast.xml`, deployed by `.github/workflows/pages.yml` when a push to `main` changes something
under `updater/` or the workflow itself, or when the workflow is run by hand.

It is checked in rather than generated at deploy time on purpose. The EdDSA signature on
each enclosure is made with a private key that never leaves the maintainer's login
keychain, so no CI job can produce one, and that is the point: the key that makes an update
installable must not be anywhere a runner can reach.

Regenerate it with `make release`, which runs `Scripts/appcast.sh` and commits the result. Do not
hand-edit it. The signatures cover the archives, not this XML, and the feed itself is not signed
(`SURequireSignedFeed` is not set), so its text is trusted exactly as served: an edit that points
an item at an archive other than the one its signature was made over gets that update refused on
every installed copy, and nothing here catches it first.
