#!/bin/bash
# Crea un certificado propio de firma de código ("Hey Claude Dev") en el llavero de inicio de sesión.
# Con él la firma de la app no cambia entre compilaciones y macOS conserva los permisos
# (micrófono, voz, Accesibilidad, Grabación de pantalla, Automatización). Se ejecuta una sola vez.
set -euo pipefail
NAME="Hey Claude Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -v -p codesigning | grep -q "$NAME"; then echo "Ya existe la identidad \"$NAME\"."; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "$TMP/ext.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:heyclaude -name "$NAME" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:heyclaude -name "$NAME"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P heyclaude -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Confiar en el certificado para firma de código (puede pedir tu contraseña una vez)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
security find-identity -v -p codesigning | grep "$NAME" && echo "Identidad creada. Recompila con app/build.sh; la primera vez macOS volverá a pedir los permisos."
