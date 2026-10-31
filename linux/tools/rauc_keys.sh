#!/usr/bin/env bash
# rauc_keys.sh [DIR] - make the development RAUC keys once (docs/plan_rauc.md,
# step 1.3): a CA and a code-signing certificate issued by it.
#
#   DIR (default ~/.de25_rauc_keys, or RAUC_KEYS)
#     ca.cert.pem       goes into the image as /etc/rauc/keyring.pem
#     ca.key.pem        signs signing certificates; nothing else
#     signing.cert.pem  signs bundles (extendedKeyUsage=codeSigning, which the
#     signing.key.pem   board's check-purpose=codesign requires)
#
# Never in the repository (it is public). Existing keys are kept: a new CA
# would make every board refuse bundles until its image is replaced.
# A second key pair to test refusals: rauc_keys.sh /some/other/dir
set -euo pipefail

KEYS="${1:-${RAUC_KEYS:-$HOME/.de25_rauc_keys}}"
if [[ -f "${KEYS}/signing.key.pem" && -f "${KEYS}/ca.cert.pem" ]]; then
    echo ">> keys already in ${KEYS}"
    exit 0
fi
mkdir -p "${KEYS}"
chmod 700 "${KEYS}"
cd "${KEYS}"
NAME="de25-std"
openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout ca.key.pem -out ca.cert.pem \
    -subj "/O=${NAME}/CN=${NAME} development CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey rsa:4096 -nodes -keyout signing.key.pem -out signing.csr.pem \
    -subj "/O=${NAME}/CN=${NAME} development signing" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > leaf.ext
openssl x509 -req -in signing.csr.pem -CA ca.cert.pem -CAkey ca.key.pem -CAcreateserial \
    -days 3650 -extfile leaf.ext -out signing.cert.pem 2>/dev/null
rm -f signing.csr.pem leaf.ext
chmod 600 ./*.key.pem
# (OpenSSL before 3.2 has no "-purpose codesign": check the extension itself)
openssl verify -CAfile ca.cert.pem signing.cert.pem >/dev/null
openssl x509 -in signing.cert.pem -noout -ext extendedKeyUsage | grep -q "Code Signing" \
    || { echo "ERROR: signing.cert.pem has no codeSigning usage"; exit 1; }
echo ">> keys in ${KEYS}: ca.cert.pem (-> /etc/rauc/keyring.pem), signing.{cert,key}.pem"
