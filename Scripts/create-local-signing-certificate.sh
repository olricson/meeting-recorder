#!/bin/zsh
set -euo pipefail

identity="MeetingRecorder Local Code Signing"
temporary="$(/usr/bin/mktemp -d /tmp/meeting-recorder-cert.XXXXXX)"
trap '/bin/rm -rf "$temporary"' EXIT
script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
transfer_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"

if /usr/bin/security find-certificate -c "$identity" -p \
  "$HOME/Library/Keychains/login.keychain-db" > "$temporary/certificate.pem"; then
  /usr/bin/security add-trusted-cert -r trustRoot \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    "$temporary/certificate.pem"
  print "Trusted the existing '${identity}' certificate in the login keychain."
  exit 0
fi

/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
  -config "$repo_dir/AppResources/CodeSigningCertificate.cnf" \
  -keyout "$temporary/private-key.pem" \
  -out "$temporary/certificate.pem"
/usr/bin/openssl pkcs12 -export -passout "pass:${transfer_password}" \
  -inkey "$temporary/private-key.pem" \
  -in "$temporary/certificate.pem" \
  -name "$identity" \
  -out "$temporary/identity.p12"

/usr/bin/security import "$temporary/identity.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$transfer_password" -T /usr/bin/codesign -T /usr/bin/security
/usr/bin/security add-trusted-cert -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$temporary/certificate.pem"

print "Created and trusted '${identity}' in the login keychain."
print "Keep a separate encrypted backup if this identity will be used to sign future updates."
