#!/bin/sh
set -eu

CA_DIR="/tmp/deploio-ca"
CONFIG_FILE="/tmp/deploio-opensearch-dashboards.yml"
DOCS_URL="https://docs.nine.ch/docs/deplo-io/configuration/deploio-connecting-to-services"

# The public endpoint of OpenSearch listens on port 443. With private
# networking, Deploio injects the port of the endpoint in the service mesh.
DEFAULT_PORT=443

export SERVER_PORT="${PORT:-8080}"

# Quote a value as a single-quoted YAML scalar, in which only the quote itself
# needs escaping.
yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# URL of an OpenSearch endpoint. The public endpoint speaks HTTPS only, while
# the endpoint in the service mesh of private networking speaks plain HTTP, as
# the mesh encrypts the traffic itself. The variables look the same for both,
# so the scheme is probed; any HTTP response, even 401, settles it. An
# endpoint that does not answer at all is assumed to be HTTPS on port 443 and
# plain HTTP on any other port.
endpoint_of() {
    if curl -s -k -m 5 -o /dev/null "https://$1:$2/"; then
        echo "https://$1:$2"
    elif curl -s -m 5 -o /dev/null "http://$1:$2/"; then
        echo "http://$1:$2"
    else
        echo "Warning: $1:$2 does not answer, guessing the scheme from the port" >&2
        if [ "$2" = 443 ]; then echo "https://$1:$2"; else echo "http://$1:$2"; fi
    fi
}

echo "Configuring ${DEPLOIO_APP_NAME:-opensearch-dashboards} (release ${DEPLOIO_RELEASE_NAME:-unknown})"

rm -rf "${CA_DIR}" "${CONFIG_FILE}"
mkdir -p "${CA_DIR}"

# Dashboards connects to a single cluster, so exactly one reference is picked.
# Names are sorted, and OPENSEARCH_DASHBOARDS_SERVICE overrides.
references="$(env | sed -n 's/^NINE_OS_\([A-Z0-9_]*\)_FQDN=.*/\1/p' | sort | tr '\n' ' ')"

selected=""
if [ -n "${OPENSEARCH_DASHBOARDS_SERVICE:-}" ]; then
    # Reference names are upper-cased with hyphens turned into underscores in
    # the variable names, so normalise the user's spelling the same way.
    wanted="$(echo "${OPENSEARCH_DASHBOARDS_SERVICE}" | tr 'a-z-' 'A-Z_')"
    for reference in ${references}; do
        if [ "${reference}" = "${wanted}" ]; then
            selected="${reference}"
            break
        fi
    done

    if [ -z "${selected}" ]; then
        echo "OPENSEARCH_DASHBOARDS_SERVICE=${OPENSEARCH_DASHBOARDS_SERVICE} matches none of the OpenSearch service references: ${references:-none}" >&2
        exit 1
    fi
else
    count=0
    for reference in ${references}; do
        [ -n "${selected}" ] || selected="${reference}"
        count=$((count + 1))
    done

    [ "${count}" -le 1 ] ||
        echo "Warning: ${count} OpenSearch service references found, using ${selected}. Set OPENSEARCH_DASHBOARDS_SERVICE=<reference name> to choose another."
fi

if [ -n "${selected}" ]; then
    prefix="NINE_OS_${selected}_"
    label="$(echo "${selected}" | tr 'A-Z_' 'a-z-')"
    display="${DEPLOIO_PROJECT_NAME:+${DEPLOIO_PROJECT_NAME} / }${label}"

    fqdn="$(printenv "${prefix}FQDN")"
    port="$(printenv "${prefix}PORT" || echo "${DEFAULT_PORT}")"
    user="$(printenv "${prefix}USER" || echo '')"
    password="$(printenv "${prefix}PASSWORD" || echo '')"
    certificate="$(printenv "${prefix}CA_CERT" || echo '')"
    endpoint="$(endpoint_of "${fqdn}" "${port}")"

    # Without the security plugin, Dashboards authenticates only its own
    # requests with opensearch.username and opensearch.password and sends the
    # requests it makes for a browser without credentials. A custom header is
    # added to every request and cannot be overridden by the browser.
    authorization="Basic $(printf '%s:%s' "${user}" "${password}" | base64 -w0)"

    # The file holds the credentials, so it is private before anything is in it.
    : > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    {
        echo "opensearch.hosts: [$(yaml_quote "${endpoint}")]"
        echo "opensearch.username: $(yaml_quote "${user}")"
        echo "opensearch.password: $(yaml_quote "${password}")"
        echo "opensearch.customHeaders: {Authorization: $(yaml_quote "${authorization}")}"
    } >> "${CONFIG_FILE}"

    # The certificate of an On-Demand service does not match its host name,
    # so the chain is verified without checking the host name.
    if [ "${endpoint%%:*}" = http ]; then
        verification="none, plain HTTP in the service mesh"
    elif [ -n "${certificate}" ]; then
        file="${CA_DIR}/os-${label}.pem"
        printf '%s\n' "${certificate}" > "${file}"
        chmod 644 "${file}"
        verification=certificate
        echo "opensearch.ssl.certificateAuthorities: [$(yaml_quote "${file}")]" >> "${CONFIG_FILE}"
    else
        verification=none
    fi
    echo "opensearch.ssl.verificationMode: ${verification%%,*}" >> "${CONFIG_FILE}"

    # Options on the command line replace the default configuration file, so
    # it is named again before the generated one.
    [ "${1:-}" != "opensearch-dashboards" ] ||
        set -- "$@" --config=config/opensearch_dashboards.yml --config="${CONFIG_FILE}"

    echo "Configured service: ${display} (${endpoint}, verificationMode=${verification})"
elif [ -z "${OPENSEARCH_HOSTS:-}" ]; then
    # OPENSEARCH_HOSTS and friends configure a cluster by hand.
    echo "No OpenSearch service references found, see ${DOCS_URL}" >&2
    exit 1
fi

cd /usr/share/opensearch-dashboards
exec ./opensearch-dashboards-docker-entrypoint.sh "$@"
