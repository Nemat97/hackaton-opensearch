The OpenSearch Dashboards version can be set with the `OPENSEARCH_DASHBOARDS_VERSION` build argument. It defaults to `3`; use `2` for a version 2 service. Dashboards refuses to work with a cluster of another major version and warns about one of an older minor version.

## Configuration

`entrypoint.sh` maps the `NINE_OS_<NAME>_*` [service variables](https://docs.nine.ch/docs/deplo-io/configuration/deploio-connecting-to-services) of a single OpenSearch reference into a configuration file at `/tmp/deploio-opensearch-dashboards.yml`, which is loaded after the bundled `opensearch_dashboards.yml`. Dashboards connects to exactly one cluster, so with several references the first name in sorted order is used; set `OPENSEARCH_DASHBOARDS_SERVICE=<reference name>` to pick another. Without any reference the app does not start, unless the connection is configured by hand with the `OPENSEARCH_HOSTS` variables of the [official image](https://hub.docker.com/r/opensearchproject/opensearch-dashboards). Without an injected port, port 443 is used. The public endpoint speaks HTTPS only, while the endpoint in the service mesh of [private networking](https://docs.nine.ch/docs/networking/private-networking) speaks plain HTTP, as the mesh encrypts the traffic itself. Both are injected the same way, so the scheme is probed at startup.

### Authentication

The Dockerfile removes the security plugin, which would ask every visitor to log in to OpenSearch. Instead, the injected credentials are sent with every request as a custom `Authorization` header, and no header from the browser is forwarded to OpenSearch, so the basic-auth credentials of Deplo.io never reach the cluster. Protect the application using [`--basic-auth`](https://docs.nine.ch/docs/deplo-io/configuration/deploio-basic-auth).

Without the security plugin, the security, tenant and role management pages are not available. Multi-tenancy is off: all visitors share the saved objects of the service user.

### TLS

The certificate of an On-Demand service does not match the host name of the service. When a CA certificate is injected, it is written to `/tmp/deploio-ca/` and the certificate chain is verified without checking the host name (`verificationMode: certificate`). Without one the connection is encrypted but not verified.

### State

Visualizations, dashboards, index patterns and advanced settings are stored in the `.kibana` index of the cluster, so they survive deployments and are shared between replicas.

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

`compose.yaml` in the repository root starts it together with a local OpenSearch at http://localhost:8089.
