#!/bin/zsh
#
# jamf-param-crypt.zsh
#
# Admin-side tool for encrypting Jamf Pro script parameters against a
# certificate deployed to managed Macs. Only the public certificate is needed
# to encrypt; the private key lives in the .p12 that goes into a profile.
#
# Usage:
#   jamf-param-crypt.zsh create-cert <certificate-name> <output-folder>
#   jamf-param-crypt.zsh encrypt <certificate.pem>

set -euo pipefail

# Pinned to the system LibreSSL because a Homebrew OpenSSL 3 earlier in PATH
# writes .p12 files using ciphers that macOS refuses to import.
readonly OPENSSL="/usr/bin/openssl"
readonly CERT_VALIDITY_DAYS=1825
readonly KEY_SIZE=2048

die() {
    print -u2 "Error: $1"
    exit 1
}

usage() {
    print "Usage:"
    print "  ${0:t} create-cert <certificate-name> <output-folder>"
    print "  ${0:t} encrypt <certificate.pem>"
    exit 1
}

read_secret_twice() {
    local prompt="$1"
    local first second

    read -rs "first?${prompt}: "
    print -u2
    read -rs "second?Confirm: "
    print -u2

    [[ -n "$first" ]] || die "Value cannot be empty."
    [[ "$first" == "$second" ]] || die "Values do not match."

    print -rn -- "$first"
}

create_cert() {
    local cert_name="$1"
    local output_folder="$2"
    local file_base="${cert_name// /-}"
    local cert_file="${output_folder}/${file_base}.pem"
    local identity_file="${output_folder}/${file_base}.p12"

    [[ -d "$output_folder" ]] || die "Output folder does not exist: $output_folder"
    [[ ! -e "$cert_file" && ! -e "$identity_file" ]] \
        || die "Files for '$cert_name' already exist in $output_folder"

    # The unencrypted private key only ever exists in this temporary folder.
    umask 077
    local work_folder
    work_folder=$(mktemp -d)
    trap "rm -rf '$work_folder'" EXIT

    cat > "${work_folder}/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_dn
x509_extensions    = v3_ext
prompt             = no

[ req_dn ]
CN = ${cert_name}

[ v3_ext ]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, keyEncipherment, dataEncipherment
extendedKeyUsage     = emailProtection
subjectKeyIdentifier = hash
EOF

    "$OPENSSL" req -x509 \
        -newkey "rsa:${KEY_SIZE}" -nodes \
        -days "$CERT_VALIDITY_DAYS" \
        -config "${work_folder}/openssl.cnf" \
        -keyout "${work_folder}/key.pem" \
        -out "$cert_file" 2>/dev/null \
        || die "Unable to create certificate."

    local p12_password
    p12_password=$(read_secret_twice "Password for the .p12 (needed when uploading to Jamf Pro)")

    # Password passed on a file descriptor so it never appears in the process list.
    "$OPENSSL" pkcs12 -export \
        -name "$cert_name" \
        -inkey "${work_folder}/key.pem" \
        -in "$cert_file" \
        -out "$identity_file" \
        -passout fd:3 3<<<"$p12_password" \
        || die "Unable to create .p12 identity."

    print "Created:"
    print "  Public certificate (used to encrypt):   $cert_file"
    print "  Identity for the profile (keep secure): $identity_file"
    print
    print "Expires in ${CERT_VALIDITY_DAYS} days. Store the .p12 and its password in your vault."
}

encrypt_value() {
    local cert_file="$1"

    [[ -f "$cert_file" ]] || die "Certificate not found: $cert_file"

    # Read interactively rather than as an argument to keep it out of shell history.
    local secret
    secret=$(read_secret_twice "Value to encrypt")

    print -rn -- "$secret" \
        | "$OPENSSL" smime -encrypt -binary -aes256 -outform DER "$cert_file" \
        | /usr/bin/base64 \
        || die "Encryption failed."
    print
}

main() {
    (( $# >= 1 )) || usage

    case "$1" in
        create-cert)
            (( $# == 3 )) || usage
            create_cert "$2" "$3"
            ;;
        encrypt)
            (( $# == 2 )) || usage
            encrypt_value "$2"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"