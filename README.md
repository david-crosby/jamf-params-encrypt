# JAMF_Crypt

Encrypt Jamf Pro script parameters so secrets (API client credentials, uninstall passwords and similar) are not stored in plain text in policies.

Values are encrypted on an admin Mac with a public certificate. Managed Macs decrypt them at run time with the matching private key, which is deployed in a configuration profile and stored in the System keychain.

## Read this first: what it does and does not protect

This is not a perfect solution. Often it's the best available option, but be clear about what it protects before relying on it.

**It protects against:**

- Secrets being readable by anyone who can view policies or scripts in Jamf Pro.
- Secrets turning up in API responses, exports, screenshots, backups and support bundles.
- Secrets being copied out of one policy and reused elsewhere without the key.

**It does not protect against:**

- **Anyone with root or admin access on an enrolled Mac.** The private key is in the System keychain and can be used without a prompt, which is what lets the policy script run unattended. Anyone who can run commands as root can decrypt the parameters too.
- **Jamf Pro admins who can edit or download configuration profiles.** The `.p12` and its password are stored in the profile.
- **Secrets printed by your own script.** Script output is stored in the policy logs, so never print a decrypted value.

The goal is to move the secret off the Jamf Pro console and keep it on managed devices only, not to make it unreadable. Keep the blast radius small:

- Give the API client the narrowest role it needs.
- Rotate secrets and certificates on a schedule.
- Use a separate certificate per purpose or environment where practical.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `jamf-param-crypt.zsh` | Admin Mac | Creates the certificate and identity, and encrypts values. |
| `decrypt-parameters.zsh` | Managed Macs | Functions to copy into policy scripts, with example usage. |

## Setup

### 1. Create a certificate

```zsh
./jamf-param-crypt.zsh create-cert "Jamf Params 2026" ~/Secure/JamfParams
```

This creates:

- `Jamf-Params-2026.pem`: the public certificate. It's used to encrypt and isn't secret.
- `Jamf-Params-2026.p12`: the private identity. You'll be asked for a password. Store the file and password in your password vault.

The certificate is RSA 2048, self-signed, and valid for 5 years. The script uses `/usr/bin/openssl` (LibreSSL) on purpose, because macOS won't import `.p12` files made by OpenSSL 3.

### 2. Deploy the identity

In Jamf Pro, create a configuration profile with a **Certificate** payload:

- Upload the `.p12` and enter its password.
- Turn **on** "Allow all applications to access". Without it, `/usr/bin/security` can't use the key unattended.
- Turn **off** "Allow export from keychain".
- Scope it to the Macs that will run the policies.

To check it arrived, look for the identity on a target Mac:

```zsh
security find-identity /Library/Keychains/System.keychain
```

`CSSMERR_TP_NOT_TRUSTED` next to it is expected, because the certificate is self-signed. That doesn't affect decryption.

### 3. Encrypt a value

```zsh
./jamf-param-crypt.zsh encrypt ~/Secure/JamfParams/Jamf-Params-2026.pem
```

You'll be asked for the value twice, and it won't be shown or saved to shell history. Paste the base64 output into the script parameter in the policy.

### 4. Use it in a policy script

Copy the functions from `decrypt-parameters.zsh` into the top of your policy script, then:

```zsh
client_id=$(decrypt_parameter "$4") || { print "Unable to decrypt the API client ID."; exit 1; }
```

The example usage in `decrypt-parameters.zsh` decrypts `$4` to `$6`, gets a Jamf Pro API token, and uses a trap to invalidate the token and clear the variables when the script exits. Edit it to fit your needs.

## Testing by hand

To decrypt a single value on a Mac that has the profile, without any API calls:

```zsh
zsh -c 'source <(sed -n "1,35p" decrypt-parameters.zsh); decrypt_parameter "$1"; echo " rc=$?"' _ '<encrypted value>'
```

To run the full script, pass placeholders for `$1` to `$3`, as Jamf would:

```zsh
./decrypt-parameters.zsh - - - '<enc1>' '<enc2>' '<enc3>'; echo "exit=$?"
```

- The script prints nothing on success, on purpose. Check that `exit=0`.
- It needs all three parameters. Missing ones fail with "Unable to decrypt…".
- Unless you comment out the API token lines, it also contacts your Jamf Pro server.

## Rotating certificates

`security` picks the matching identity from the encrypted value itself, so old and new certificates can be installed at the same time:

1. Create a new certificate and deploy its `.p12` in a new profile, next to the old one.
2. Re-encrypt every parameter with the new `.pem` and update the policies.
3. Once every policy uses the new values, remove the old profile.

Set a reminder well before the 5-year expiry. An expired certificate still decrypts, but rotating also limits how long a leaked key stays useful.

## Troubleshooting

To see the real error, run the decrypt by hand without the script's `2>/dev/null`:

```zsh
print -rn -- '<encrypted value>' | base64 -D | sudo /usr/bin/security cms -D
```

| Error | Likely cause |
|---|---|
| `-8147` (not a recipient) | The matching identity isn't installed, or the value was encrypted with a different `.pem`. |
| `-8183` or `base64: error decoding` | The value was changed when it was copied, for example truncated or with extra characters. |
| Prompt, or hangs, in a policy | "Allow all applications to access" was off in the Certificate payload. |
| "Unable to decrypt…" with an empty parameter | The parameter isn't set in the policy. |

To see which certificate a value was encrypted for:

```zsh
print -rn -- '<encrypted value>' | base64 -D | /usr/bin/openssl asn1parse -inform DER | grep -A1 commonName
```
