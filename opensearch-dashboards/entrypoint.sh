#!/bin/sh
set -eu

CA_DIR="/tmp/deploio-ca"
CONFIG_FILE="/tmp/deploio-opensearch-dashboards.yml"
DOCS_URL="https://docs.nine.ch/docs/deplo-io/configuration/deploio-connecting-to-services"

# The public endpoint of OpenSearch listens on port 443. With private
# networking, Deploio injects the port of the endpoint in the service mesh.
DEFAULT_PORT=443

# Data sources created by this script carry this prefix in their id, so stale
# ones can be told apart from data sources created by hand.
DATA_SOURCE_PREFIX="deploio-"

export SERVER_PORT="${PORT:-8080}"

# Quote a value as a single-quoted YAML scalar, in which only the quote itself
# needs escaping.
yaml_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"
}

# Quote a value as a JSON string.
json_quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Label of a reference as shown in the UI: the name given with --service.
label_of() {
    echo "$1" | tr 'A-Z_' 'a-z-'
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

# Register the given references as data sources once the server accepts
# requests. Data sources are saved objects in the primary cluster, so they are
# created with fixed ids and overwritten on every start, and the ones of
# removed references are deleted.
register_data_sources() {
    api="http://127.0.0.1:${SERVER_PORT}/api"

    # The saved objects API answers once the server is ready and the index in
    # the primary cluster is migrated.
    attempts=0
    until [ "$(curl -s -o /dev/null -w '%{http_code}' "${api}/saved_objects/_find?type=data-source&per_page=1")" = 200 ]; do
        attempts=$((attempts + 1))
        if [ "${attempts}" -gt 300 ]; then
            echo "Dashboards did not start within 10 minutes, no data sources registered" >&2
            return 1
        fi
        sleep 2
    done

    registered=""
    for reference in "$@"; do
        prefix="NINE_OS_${reference}_"
        label="$(label_of "${reference}")"
        id="${DATA_SOURCE_PREFIX}${label}"
        eval "endpoint=\${endpoint_${reference}}"
        registered="${registered} ${id}"

        body="{\"attributes\":{
            \"title\":$(json_quote "${label}"),
            \"description\":$(json_quote "Service reference ${label}, configured by Deploio"),
            \"endpoint\":$(json_quote "${endpoint}"),
            \"auth\":{\"type\":\"username_password\",\"credentials\":{
                \"username\":$(json_quote "$(printenv "${prefix}USER" || echo '')"),
                \"password\":$(json_quote "$(printenv "${prefix}PASSWORD" || echo '')")
            }}
        }}"

        response="$(printf '%s' "${body}" | curl -s -w '\n%{http_code}' \
            -X POST "${api}/saved_objects/data-source/${id}?overwrite=true" \
            -H 'osd-xsrf: true' -H 'Content-Type: application/json' --data-binary @-)"

        if [ "${response##*
}" = 200 ]; then
            echo "Registered data source: ${label}"
        else
            echo "Registering data source ${label} failed: ${response}" >&2
        fi
    done

    existing="$(curl -s "${api}/saved_objects/_find?type=data-source&per_page=1000&fields=title" |
        grep -o "\"id\":\"${DATA_SOURCE_PREFIX}[^\"]*\"" | sed 's/^"id":"//; s/"$//')" || true

    for id in ${existing}; do
        case "${registered} " in
        *" ${id} "*) continue ;;
        esac

        curl -s -o /dev/null -X DELETE "${api}/saved_objects/data-source/${id}" -H 'osd-xsrf: true' &&
            echo "Removed data source of a removed service reference: ${id#"${DATA_SOURCE_PREFIX}"}"
    done
}

echo "Configuring ${DEPLOIO_APP_NAME:-opensearch-dashboards} (release ${DEPLOIO_RELEASE_NAME:-unknown})"

rm -rf "${CA_DIR}" "${CONFIG_FILE}"
mkdir -p "${CA_DIR}"

references="$(env | sed -n 's/^NINE_OS_\([A-Z0-9_]*\)_FQDN=.*/\1/p' | sort | tr '\n' ' ')"

# Dashboards stores its saved objects in the cluster of a single, primary
# reference: the first name in sorted order, unless
# OPENSEARCH_DASHBOARDS_SERVICE names another. All others become data sources.
primary=""
if [ -n "${OPENSEARCH_DASHBOARDS_SERVICE:-}" ]; then
    # Reference names are upper-cased with hyphens turned into underscores in
    # the variable names, so normalise the user's spelling the same way.
    wanted="$(echo "${OPENSEARCH_DASHBOARDS_SERVICE}" | tr 'a-z-' 'A-Z_')"
    for reference in ${references}; do
        if [ "${reference}" = "${wanted}" ]; then
            primary="${reference}"
            break
        fi
    done

    if [ -z "${primary}" ]; then
        echo "OPENSEARCH_DASHBOARDS_SERVICE=${OPENSEARCH_DASHBOARDS_SERVICE} matches none of the OpenSearch service references: ${references:-none}" >&2
        exit 1
    fi
else
    for reference in ${references}; do
        primary="${reference}"
        break
    done
fi

if [ -z "${primary}" ]; then
    if [ -z "${OPENSEARCH_HOSTS:-}" ]; then
        # OPENSEARCH_HOSTS and friends configure a cluster by hand.
        echo "No OpenSearch service references found, see ${DOCS_URL}" >&2
        exit 1
    fi

    cd /usr/share/opensearch-dashboards
    exec ./opensearch-dashboards-docker-entrypoint.sh "$@"
fi

# The file holds the credentials, so it is private before anything is in it.
: > "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"

# The certificate of an On-Demand service does not match its host name, so
# the chain is verified without checking the host name. Dashboards has a
# single TLS setting for all data sources, so each of them trusts the CA
# certificates of all of them. Endpoints speaking plain HTTP ignore them.
data_sources=""
data_source_cas=""
data_source_verification=certificate
for reference in ${references}; do
    prefix="NINE_OS_${reference}_"
    label="$(label_of "${reference}")"
    display="${DEPLOIO_PROJECT_NAME:+${DEPLOIO_PROJECT_NAME} / }${label}"
    fqdn="$(printenv "${prefix}FQDN")"
    port="$(printenv "${prefix}PORT" || echo "${DEFAULT_PORT}")"
    certificate="$(printenv "${prefix}CA_CERT" || echo '')"
    endpoint="$(endpoint_of "${fqdn}" "${port}")"
    # Read by register_data_sources; reference names are [A-Z0-9_] only.
    eval "endpoint_${reference}=\${endpoint}"

    file=""
    verification=none
    if [ "${endpoint%%:*}" = http ]; then
        verification="none, plain HTTP in the service mesh"
    elif [ -n "${certificate}" ]; then
        file="${CA_DIR}/os-${label}.pem"
        printf '%s\n' "${certificate}" > "${file}"
        chmod 644 "${file}"
        verification=certificate
    fi

    if [ "${reference}" != "${primary}" ]; then
        data_sources="${data_sources} ${reference}"
        if [ "${endpoint%%:*}" = http ]; then
            :
        elif [ -n "${file}" ]; then
            data_source_cas="${data_source_cas:+${data_source_cas}, }$(yaml_quote "${file}")"
        else
            data_source_verification=none
        fi

        echo "Configured service: ${display} (${endpoint}, data source)"
        continue
    fi

    user="$(printenv "${prefix}USER" || echo '')"
    password="$(printenv "${prefix}PASSWORD" || echo '')"

    # Without the security plugin, Dashboards authenticates only its own
    # requests with opensearch.username and opensearch.password and sends the
    # requests it makes for a browser without credentials. A custom header is
    # added to every request and cannot be overridden by the browser. Data
    # sources use clients of their own that authenticate with the credentials
    # stored with them.
    authorization="Basic $(printf '%s:%s' "${user}" "${password}" | base64 -w0)"

    {
        echo "opensearch.hosts: [$(yaml_quote "${endpoint}")]"
        echo "opensearch.username: $(yaml_quote "${user}")"
        echo "opensearch.password: $(yaml_quote "${password}")"
        echo "opensearch.customHeaders: {Authorization: $(yaml_quote "${authorization}")}"
        echo "opensearch.ssl.verificationMode: ${verification%%,*}"
        [ -z "${file}" ] || echo "opensearch.ssl.certificateAuthorities: [$(yaml_quote "${file}")]"
    } >> "${CONFIG_FILE}"

    echo "Configured service: ${display} (${endpoint}, verificationMode=${verification}, stores saved objects)"
done

if [ -n "${data_sources}" ]; then
    # Data source credentials are stored encrypted in the primary cluster. The
    # key has to be the same on every replica and after every restart, so
    # unless one is given it is derived from the credentials of the primary
    # reference, which can read the stored credentials anyway.
    wrapping_key="${DATA_SOURCE_ENCRYPTION_WRAPPINGKEY:-}"
    if [ -z "${wrapping_key}" ]; then
        digest="$(printf 'deploio-opensearch-dashboards:%s:%s' "${user}" "${password}" |
            sha256sum | cut -c1-64 | sed 's/../0x& /g')"
        wrapping_key=""
        for byte in ${digest}; do
            wrapping_key="${wrapping_key:+${wrapping_key}, }$(printf '%d' "${byte}")"
        done
        wrapping_key="[${wrapping_key}]"
    fi

    {
        echo "data_source.enabled: true"
        echo "data_source.encryption.wrappingKey: ${wrapping_key}"
        echo "data_source.ssl.verificationMode: ${data_source_verification}"
        [ -z "${data_source_cas}" ] || echo "data_source.ssl.certificateAuthorities: [${data_source_cas}]"
    } >> "${CONFIG_FILE}"

    [ "${data_source_verification}" = certificate ] ||
        echo "Warning: a data source without a CA certificate turns off certificate verification for all data sources"

    # shellcheck disable=SC2086 # word splitting separates the references
    register_data_sources ${data_sources} &
fi

# Options on the command line replace the default configuration file, so it
# is named again before the generated one.
[ "${1:-}" != "opensearch-dashboards" ] ||
    set -- "$@" --config=config/opensearch_dashboards.yml --config="${CONFIG_FILE}"

cd /usr/share/opensearch-dashboards
exec ./opensearch-dashboards-docker-entrypoint.sh "$@"
