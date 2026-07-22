# Zebra Browser Print SDK

`BrowserPrint-3.0.216.min.js`, vendored for task #73 (label printing).

Zebra doesn't publish this on an official CDN -- it normally ships bundled
with the Browser Print desktop app installer (zebra.com). This copy was
fetched from a community mirror,
https://github.com/jesseosb/zebra-browser-print-min (version `3.0.216` per
its own `package.json`), since no official direct-download URL exists.

Sanity-checked before vendoring: Closure-Compiler-minified (the `$jscomp`
prefix), no `eval()`, and its only two hardcoded network endpoints are
`http://127.0.0.1:9100/` and `https://127.0.0.1:9101/` -- matching Zebra's
own documented local ports for the Browser Print desktop app. No external
network calls.

If Zebra ever publishes an official direct download, prefer that over this
mirror on the next update.
