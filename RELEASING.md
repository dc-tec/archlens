# Release ArchLens

ArchLens releases use signed tags from a validated `main` branch.

1. Confirm that `main` is clean and synchronized with `origin/main`.
2. Add the release's notable user-facing changes to `CHANGELOG.md` and set the
   package version in `flake.nix` to the release version without the `-dev`
   suffix.
3. Evaluate every supported system, run the current-system validation, and run
   the local performance report:

   ```sh
   nix flake show path:. --all-systems
   nix flake check path:. --print-build-logs
   nix run path:.#benchmark
   ```

4. Commit the version change with a conventional, DCO-signed, GPG-signed
   commit and push `main`.
5. Wait for the Linux and macOS validation jobs to pass.
6. Create and push a signed annotated tag:

   ```sh
   git tag -s vX.Y.Z -m "ArchLens vX.Y.Z"
   git push origin vX.Y.Z
   ```

7. Create the GitHub release from the tag:

   ```sh
   gh release create vX.Y.Z --verify-tag --generate-notes
   ```

8. Set the package version on `main` to the next patch development version, such
   as `0.1.1-dev` after `0.1.0`. Commit the change with a conventional,
   DCO-signed, GPG-signed commit and push `main` before starting further
   development.
