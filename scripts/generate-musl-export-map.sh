#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <consumer-elf> <provider-selfreloc-elf> <output.map>" >&2
    exit 1
fi

CONSUMER_ELF=$1
PROVIDER_ELF=$2
OUT=$3
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
ROOTDIR=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
TARGET=${TARGET:-arm-uclinuxfdpiceabi}
READELF=${READELF:-${ROOTDIR}/toolchain/bin/${TARGET}-readelf}

[ -x "${READELF}" ] || {
    echo "ERROR: missing target readelf: ${READELF}" >&2
    exit 1
}
[ -f "${CONSUMER_ELF}" ] || {
    echo "ERROR: missing consumer ELF: ${CONSUMER_ELF}" >&2
    exit 1
}
[ -f "${PROVIDER_ELF}" ] || {
    echo "ERROR: missing provider ELF: ${PROVIDER_ELF}" >&2
    exit 1
}

TMP=${OUT}.tmp

{
    echo "{"
    echo "  global:"
    {
        LC_ALL=C "${READELF}" -Ws "${CONSUMER_ELF}" |
        awk '
            $7 != "UND" { next }
            $4 != "FUNC" && $4 != "OBJECT" && $4 != "NOTYPE" { next }
            $8 == "" { next }
            !seen[$8]++ { print $8 }
        ' |
        sed 's/@.*$//'

        LC_ALL=C "${READELF}" -rW "${PROVIDER_ELF}" |
        awk '
            /R_ARM_RELATIVE/ { next }
            /R_ARM_NONE/ { next }
            /[[:space:]][A-Za-z_][A-Za-z0-9_@.]*$/ {
                name = $NF
                sub(/@.*/, "", name)
                if (name != "" && name != "UND") print name
            }
        '
    } |
        sort -u |
        sed 's/^/    /; s/$/;/'
    echo "  local:"
    echo "    *;"
    echo "};"
} > "${TMP}"

mv "${TMP}" "${OUT}"
