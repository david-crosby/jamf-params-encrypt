#!/bin/zsh
#
# decrypt-parameters.zsh
#
# Functions for Jamf Pro policy scripts that receive parameters encrypted with
# jamf-param-crypt.zsh. Copy the functions into the top of a policy script.
#
# The matching .p12 must be deployed in a configuration profile Certificate
# payload with access for all apps allowed, otherwise /usr/bin/security cannot
# use the private key without a prompt. Export from keychain should be off.
#
# Parameters used in the example below:
#   $4  Jamf API client ID (encrypted)
#   $5  Jamf API client secret (encrypted)
#   $6  Product uninstall password (encrypted)

readonly SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

decrypt_parameter() {
    setopt localoptions pipefail
    local encrypted_value="$1"
    local decrypted_value

    [[ -n "$encrypted_value" ]] || return 1

    # security picks the right identity from the envelope itself, so old and
    # new certificates can sit side by side during rotation.
    decrypted_value=$(print -rn -- "$encrypted_value" \
        | /usr/bin/base64 -D \
        | /usr/bin/security cms -D -k "$SYSTEM_KEYCHAIN" 2>/dev/null) \
        || return 1

    [[ -n "$decrypted_value" ]] || return 1
    print -rn -- "$decrypted_value"
}

jamf_url() {
    local url
    url=$(/usr/bin/defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url)
    print -rn -- "${url%/}"
}

# get_api_token() {
#     local server_url="$1"
#     local client_id="$2"
#     local client_secret="$3"
#     local response

#     # Both credentials go in via stdin so neither shows up in the process list.
#     response=$(print -rn -- "client_id=${client_id}&grant_type=client_credentials&client_secret=$(urlencode "$client_secret")" \
#         | /usr/bin/curl --silent --fail \
#             --request POST \
#             --header "Content-Type: application/x-www-form-urlencoded" \
#             --data @- \
#             "${server_url}/api/oauth/token") \
#         || return 1

#     print -rn -- "$response" | /usr/bin/plutil -extract access_token raw -o - -
# }

invalidate_api_token() {
    local server_url="$1"
    local token="$2"

    print -r -- "Authorization: Bearer ${token}" \
        | /usr/bin/curl --silent --output /dev/null \
            --request POST \
            --header @- \
            "${server_url}/api/v1/auth/invalidate-token"
}

urlencode() {
    local value="$1"
    local encoded=""
    local character

    for character in ${(s::)value}; do
        case "$character" in
            [a-zA-Z0-9.~_-]) encoded+="$character" ;;
            *) encoded+=$(printf '%%%02X' "'$character") ;;
        esac
    done

    print -rn -- "$encoded"
}

# Example usage

client_id=$(decrypt_parameter "$4") || { print "Unable to decrypt the API client ID."; exit 1; }
client_secret=$(decrypt_parameter "$5") || { print "Unable to decrypt the API client secret."; exit 1; }
uninstall_password=$(decrypt_parameter "$6") || { print "Unable to decrypt the uninstall password."; exit 1; }

echo "Decrypted parameters:"
echo "  Client ID: $client_id"
echo "  Client Secret: $client_secret" 

# server_url=$(jamf_url)
# api_token=$(get_api_token "$server_url" "$client_id" "$client_secret") \
#     || { print "Unable to get a Jamf Pro API token."; exit 1; }

# # Clear the token and secrets however the script ends.
# trap 'invalidate_api_token "$server_url" "$api_token"; unset client_id client_secret uninstall_password api_token' EXIT

# # Update extension attributes and run the uninstall here. Never print the
# # secrets: script output is stored in the policy logs.