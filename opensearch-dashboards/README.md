The OpenSearch Dashboards version can be set with the `OPENSEARCH_DASHBOARDS_VERSION` build argument. It defaults to `3`; use `2` for a version 2 service. Dashboards refuses to work with a cluster of another major version and warns about one of an older minor version.

## Configuration

`entrypoint.sh` maps the `NINE_OS_<NAME>_*` [service variables](https://docs.nine.ch/docs/deplo-io/configuration/deploio-connecting-to-services) into a configuration file at `/tmp/deploio-opensearch-dashboards.yml`, which is loaded after the bundled `opensearch_dashboards.yml`. Without any reference the app does not start, unless the connection is configured by hand with the `OPENSEARCH_HOSTS` variables of the [official image](https://hub.docker.com/r/opensearchproject/opensearch-dashboards). Deplo.io injects no port for OpenSearch, so port 443 is used.

### Multiple clusters

Dashboards stores its saved objects in a single cluster, the one of the primary reference. It is the first reference name in sorted order; set `OPENSEARCH_DASHBOARDS_SERVICE=<reference name>` to pick another. It appears as `Local cluster` in the UI.

Every other reference becomes a [data source](https://docs.opensearch.org/latest/dashboards/management/multi-data-sources/), named after the reference. Once the server is up, `entrypoint.sh` creates them through the saved objects API with the ids `deploio-<name>`, overwriting them on every start so changed credentials are picked up, and deletes the `deploio-` data sources of references that no longer exist. Data sources created by hand are left alone. With a single reference, the data source feature stays off; data sources left over from earlier references are then hidden rather than deleted, and removed as soon as a second reference is added again.

The credentials of data sources are stored encrypted in the primary cluster. The key must be the same on every replica and after every restart, so it is derived from the credentials of the primary reference; set `DATA_SOURCE_ENCRYPTION_WRAPPINGKEY` to a list of 32 numbers to use another. When the primary credentials change, the data sources are recreated with the new key on the next start.

Data sources connect with the credentials of their own reference; the `Authorization` header of the primary reference is only sent to the primary cluster.

### Authentication

The Dockerfile removes the security plugin, which would ask every visitor to log in to OpenSearch. Instead, the injected credentials are sent with every request as a custom `Authorization` header, and no header from the browser is forwarded to OpenSearch, so the basic-auth credentials of Deplo.io never reach the cluster. Protect the application using [`--basic-auth`](https://docs.nine.ch/docs/deplo-io/configuration/deploio-basic-auth).

Without the security plugin, the security, tenant and role management pages are not available. Multi-tenancy is off: all visitors share the saved objects of the service user.

### TLS

The certificate of an On-Demand service does not match the host name of the service. When a CA certificate is injected, it is written to `/tmp/deploio-ca/` and the certificate chain is verified without checking the host name (`verificationMode: certificate`). Without one the connection is encrypted but not verified.

Dashboards has one TLS setting for all data sources, so every data source trusts the CA certificates of all data sources, and a single data source without a CA certificate turns verification off for all of them. The primary cluster is configured separately.

### State

Visualizations, dashboards, index patterns, data sources and advanced settings are stored in the `.kibana` index of the primary cluster, so they survive deployments and are shared between replicas.

## Building and Running Locally

```shell
docker build --tag on-demand-opensearch-dashboards .
```

Run with simulated Deploio environment variables:

```shell
docker run --rm --publish 8080:8080 \
  --env NINE_OS_SEARCH_FQDN=opensearch.example.com \
  --env NINE_OS_SEARCH_USER=admin \
  --env NINE_OS_SEARCH_PASSWORD=secret \
  --env NINE_OS_SEARCH_CA_CERT="$(cat ca.pem)" \
  on-demand-opensearch-dashboards
```

Add a second set of `NINE_OS_<NAME>_*` variables for a data source. `compose.yaml` in the repository root starts it together with two local OpenSearch clusters at http://localhost:8089.
