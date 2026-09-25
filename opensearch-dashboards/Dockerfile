ARG OPENSEARCH_DASHBOARDS_VERSION=3

FROM opensearchproject/opensearch-dashboards:${OPENSEARCH_DASHBOARDS_VERSION}

# The security plugin asks every visitor to log in to OpenSearch. A service
# reference carries a single user, whose credentials the server uses for all
# requests instead, so the app is protected with Deploio's basic auth like the
# other administration tools. The upstream entrypoint removes the plugin at
# every start when DISABLE_SECURITY_DASHBOARDS_PLUGIN is set; removing it at
# build time keeps the start fast and the image immutable.
RUN opensearch-dashboards-plugin remove securityDashboards

# Replaces the upstream configuration, which points to the demo cluster and
# configures the removed security plugin.
COPY --chmod=644 opensearch_dashboards.yml /usr/share/opensearch-dashboards/config/opensearch_dashboards.yml
COPY --chmod=755 entrypoint.sh /deploio/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/deploio/entrypoint.sh"]
CMD ["opensearch-dashboards"]
