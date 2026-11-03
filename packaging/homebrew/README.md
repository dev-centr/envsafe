# Homebrew tap bump

`envsafe` ships through the tap [dev-centr/homebrew-tap](https://github.com/dev-centr/homebrew-tap):

```sh
brew install dev-centr/tap/envsafe
```

The release workflow rewrites `Formula/envsafe.rb` in the tap after it publishes a tag, but only when the
repository secret `HOMEBREW_TAP_TOKEN` is set. That secret should hold a fine-grained token with
**Contents: read and write** on `dev-centr/homebrew-tap` only. Without the secret, the step prints a warning and skips the bump.

## Manual bump

From a clone of this repo, after the release is published:

```sh
v=0.2.1
gh release download "v$v" -R dev-centr/envsafe -p SHA256SUMS.txt -D /tmp/envsafe-$v
bash packaging/homebrew/render-formula.sh "$v" /tmp/envsafe-$v/SHA256SUMS.txt > ../homebrew-tap/Formula/envsafe.rb
cd ../homebrew-tap && git add Formula/envsafe.rb && git commit -m "envsafe $v" && git push
```
