# Golden corpus (externally authored)

Committed FITS reference files authored by **CFITSIO 4.6.4** and **Astropy** (generators in
`interop/`), consumed hermetically by `test/golden.zig`. These prove cross-tool
interoperability and byte-exact codec parity that pure-Zig round-trips cannot
(`X-FIXTURES`/`X-XVAL`/`X-CONF`/`X-INTEROP`/`X-SUM`).

**Do not edit by hand.** Regenerate with:

```
make -C interop golden && make -C interop normalize
```

Provenance, the generating tool, the consuming task, and expected values for every file live
in `MANIFEST.json`. `test/golden.zig` skips cleanly when this corpus is absent and asserts
against it (including a per-file SHA-256 check) when present.
